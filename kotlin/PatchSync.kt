package com.halcyon.patchsync

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.transformWhile
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.random.Random
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

/*
 * PatchSync: copies a bank of patches from a Halcyon Tern to the desktop
 * library, over a slow SysEx link.
 *
 * The hardware answers one request at a time, so device I/O is serialised
 * through a single actor-style channel. Parsing and writing to disk are
 * independent and run concurrently, bounded by a semaphore. Progress is
 * exposed as a StateFlow for the UI; cancelling the scope cancels the
 * whole transfer cleanly.
 */

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

@JvmInline
value class Slot(val index: Int) {
    init { require(index in 0..127) { "slot out of range: $index" } }
    override fun toString() = "%03d".format(index + 1)
}

data class Patch(
    val slot: Slot,
    val name: String,
    val category: String,
    val parameters: Map<String, Float>,
)

sealed interface SyncState {
    data object Idle : SyncState
    data class Running(val done: Int, val total: Int, val current: Slot?) : SyncState {
        val fraction: Float get() = if (total == 0) 0f else done.toFloat() / total
    }
    data class Finished(val copied: Int, val skipped: List<Slot>, val took: Duration) : SyncState
    data class Failed(val cause: Throwable) : SyncState
}

class DeviceTimeout(slot: Slot) : Exception("no reply for slot $slot")

// ---------------------------------------------------------------------------
// Device link
// ---------------------------------------------------------------------------

/** The raw transport: one SysEx request, one reply. Not safe to call concurrently. */
fun interface SysExPort {
    suspend fun request(message: ByteArray): ByteArray
}

/**
 * Serialises every request to the device through one coroutine, so callers
 * can ask from anywhere without ever interleaving two SysEx messages.
 */
class DeviceLink(scope: CoroutineScope, private val port: SysExPort) {
    private class Request(
        val slot: Slot,
        val timeout: Duration,
        val reply: CompletableDeferred<ByteArray>,
    )

    private val queue = Channel<Request>(capacity = Channel.UNLIMITED)

    init {
        scope.launch {
            for (req in queue) {
                // The timeout lives here, in the one coroutine that owns the
                // port: a slot that never answers costs its own timeout and
                // does not eat into the time of the requests queued behind it.
                val message = byteArrayOf(0xF0.toByte(), 0x7D, 0x21, req.slot.index.toByte(), 0xF7.toByte())
                val bytes = withTimeoutOrNull(req.timeout) { port.request(message) }
                if (bytes != null) req.reply.complete(bytes)
                else req.reply.completeExceptionally(DeviceTimeout(req.slot))
            }
        }
    }

    suspend fun dumpSlot(slot: Slot, timeout: Duration = 2.seconds): ByteArray {
        val reply = CompletableDeferred<ByteArray>()
        queue.send(Request(slot, timeout, reply))
        return reply.await()
    }

    fun close() = queue.close()
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

private val PARAMETER_NAMES = listOf(
    "osc1.wave", "osc1.pw", "osc2.fine", "mix", "vcf.cutoff", "vcf.res",
    "vcf.env", "env.attack", "env.decay", "env.sustain", "env.release", "lfo.rate",
)

private val CATEGORIES = listOf("bass", "lead", "pad", "pluck", "keys", "fx", "texture", "drum")

fun parsePatch(slot: Slot, sysex: ByteArray): Patch {
    require(sysex.first() == 0xF0.toByte() && sysex.last() == 0xF7.toByte()) { "not a SysEx frame" }
    val body = sysex.copyOfRange(4, sysex.size - 1)
    val name = body.copyOfRange(0, 12).decodeToString().trimEnd(' ', '\u0000')
    val category = CATEGORIES[body[12].toInt() % CATEGORIES.size]
    val params = PARAMETER_NAMES.withIndex().associate { (i, key) ->
        key to (body[13 + i].toInt() and 0x7F) / 127f
    }
    return Patch(slot, name.ifBlank { "Init $slot" }, category, params)
}

// ---------------------------------------------------------------------------
// Sync
// ---------------------------------------------------------------------------

interface Library {
    suspend fun save(patch: Patch)
}

class PatchSync(
    private val link: DeviceLink,
    private val library: Library,
    private val writeParallelism: Int = 4,
) {
    private val _state = MutableStateFlow<SyncState>(SyncState.Idle)
    val state: StateFlow<SyncState> = _state.asStateFlow()

    suspend fun copyBank(slots: List<Slot>): SyncState.Finished = coroutineScope {
        val started = System.nanoTime()
        val writers = Semaphore(writeParallelism)
        val skipped = mutableListOf<Slot>()
        _state.value = SyncState.Running(0, slots.size, null)

        val writes = slots.map { slot ->
            // Device reads are serialised by DeviceLink; the rest overlaps.
            val bytes = try {
                link.dumpSlot(slot)
            } catch (e: DeviceTimeout) {
                skipped += slot
                null
            }
            _state.update { s -> (s as SyncState.Running).copy(current = slot) }

            async(Dispatchers.Default) {
                if (bytes != null) {
                    val patch = parsePatch(slot, bytes)
                    writers.withPermit { library.save(patch) }
                }
                _state.update { s -> (s as SyncState.Running).copy(done = s.done + 1) }
            }
        }
        writes.awaitAll()

        val took = ((System.nanoTime() - started) / 1_000_000).milliseconds
        SyncState.Finished(slots.size - skipped.size, skipped.toList(), took)
            .also { _state.value = it }
    }
}

/** Progress as whole percentages, without repeats, ending when the sync ends. */
fun StateFlow<SyncState>.percentages(): Flow<Int> =
    transformWhile { s ->
        when (s) {
            is SyncState.Running -> emit((s.fraction * 100).toInt())
            is SyncState.Finished -> emit(100)
            SyncState.Idle, is SyncState.Failed -> Unit
        }
        s !is SyncState.Finished && s !is SyncState.Failed
    }.distinctUntilChanged()

// ---------------------------------------------------------------------------
// A simulated device and library, so the file runs on its own.
// ---------------------------------------------------------------------------

private val NAMES = listOf(
    "Saltmarsh Bs", "Glass Heron", "Low Tide", "Lighthouse", "Copper Plk", "Night Ferry",
    "Brine Arp", "Gull Chirp", "Undertow", "SeaGlass Bl", "Fog Horn", "Kelp Forest",
)

class SimulatedTern(private val rng: Random = Random(14)) : SysExPort {
    override suspend fun request(message: ByteArray): ByteArray {
        val slot = message[3].toInt()
        delay(rng.nextLong(15, 40)) // 31.25 kbaud is not fast
        if (slot == 9) delay(5_000) // a slot the firmware never answers
        val name = NAMES[slot % NAMES.size].padEnd(12).encodeToByteArray()
        val params = ByteArray(PARAMETER_NAMES.size) { rng.nextInt(0, 128).toByte() }
        return byteArrayOf(0xF0.toByte(), 0x7D, 0x22, slot.toByte()) +
            name + byteArrayOf(rng.nextInt(0, 8).toByte()) + params + byteArrayOf(0xF7.toByte())
    }
}

class PrintingLibrary : Library {
    override suspend fun save(patch: Patch) = withContext(Dispatchers.IO) {
        delay(Random.nextLong(5, 60))
        val cutoff = patch.parameters.getValue("vcf.cutoff")
        println("  saved ${patch.slot}  %-12s  %-8s  cutoff %.2f".format(patch.name, patch.category, cutoff))
    }
}

fun main() = runBlocking {
    val link = DeviceLink(this, SimulatedTern())
    val sync = PatchSync(link, PrintingLibrary())

    val progress = launch {
        sync.state.percentages().collect { pct ->
            if (pct % 25 == 0) println("[$pct%]")
        }
    }

    val result = sync.copyBank((0 until 16).map(::Slot))
    progress.join()
    link.close()

    println("copied ${result.copied} patches in ${result.took}; skipped ${result.skipped.joinToString()}")
}
