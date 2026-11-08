"""Patch model for Halcyon Instruments synthesizers.

A *patch* is a named snapshot of every parameter on an instrument: oscillator
shapes, filter settings, envelope times, modulation routings. This module
defines a typed, immutable representation of patches and the operations a
librarian needs: validation, morphing between two patches, diffing, and a
stable text serialisation that survives round trips and version control.

The model is deliberately free of I/O. Reading and writing files is the job
of the caller; everything here is a pure function of its inputs.
"""

from __future__ import annotations

import math
from collections.abc import Iterable, Iterator, Mapping
from dataclasses import dataclass, field, replace
from enum import Enum, auto
from typing import Final, NamedTuple, Self

__all__ = [
    "Waveform",
    "FilterMode",
    "Envelope",
    "Oscillator",
    "Filter",
    "Route",
    "Patch",
    "PatchError",
    "Change",
    "morph",
    "diff",
    "dumps",
    "loads",
]

FORMAT_VERSION: Final = 3
MIN_TIME_S: Final = 0.001
MAX_TIME_S: Final = 30.0


class PatchError(ValueError):
    """Raised when a patch is structurally valid Python but musically invalid."""


class Waveform(Enum):
    SINE = auto()
    TRIANGLE = auto()
    SAW = auto()
    SQUARE = auto()
    NOISE = auto()

    @property
    def has_pulse_width(self) -> bool:
        return self is Waveform.SQUARE


class FilterMode(Enum):
    LOW_PASS = "lp"
    BAND_PASS = "bp"
    HIGH_PASS = "hp"
    NOTCH = "notch"


def _clamp(value: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, value))


def _lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def _log_lerp(a: float, b: float, t: float) -> float:
    """Interpolate on a log scale: the right curve for times and frequencies.

    Halfway between 10 ms and 1 s should sound like 100 ms, not 505 ms.
    """
    return math.exp(_lerp(math.log(a), math.log(b), t))


@dataclass(frozen=True, slots=True)
class Envelope:
    """An ADSR envelope. Times are in seconds, sustain is a level in [0, 1]."""

    attack: float = 0.005
    decay: float = 0.25
    sustain: float = 0.7
    release: float = 0.4

    def __post_init__(self) -> None:
        for name in ("attack", "decay", "release"):
            value = getattr(self, name)
            if not MIN_TIME_S <= value <= MAX_TIME_S:
                raise PatchError(f"envelope {name} {value!r}s is outside {MIN_TIME_S}–{MAX_TIME_S}s")
        if not 0.0 <= self.sustain <= 1.0:
            raise PatchError(f"sustain level {self.sustain!r} must be within 0..1")

    def level_at(self, t: float, gate_length: float) -> float:
        """Envelope output at time *t* for a note held for *gate_length* seconds."""
        if t < 0:
            return 0.0
        held = self._held_level(min(t, gate_length))
        if t <= gate_length:
            return held
        elapsed = t - gate_length
        return held * max(0.0, 1.0 - elapsed / self.release)

    def _held_level(self, t: float) -> float:
        if t < self.attack:
            return t / self.attack
        t -= self.attack
        if t < self.decay:
            return _lerp(1.0, self.sustain, t / self.decay)
        return self.sustain

    def blend(self, other: Envelope, t: float) -> Envelope:
        return Envelope(
            attack=_log_lerp(self.attack, other.attack, t),
            decay=_log_lerp(self.decay, other.decay, t),
            sustain=_lerp(self.sustain, other.sustain, t),
            release=_log_lerp(self.release, other.release, t),
        )


@dataclass(frozen=True, slots=True)
class Oscillator:
    waveform: Waveform = Waveform.SAW
    octave: int = 0
    detune_cents: float = 0.0
    level: float = 0.8
    pulse_width: float = 0.5

    def __post_init__(self) -> None:
        if not -3 <= self.octave <= 3:
            raise PatchError(f"octave {self.octave} out of range -3..3")
        if abs(self.detune_cents) > 100:
            raise PatchError("detune beyond ±100 cents; use the octave or a semitone offset")
        if not 0.05 <= self.pulse_width <= 0.95:
            raise PatchError("pulse width must stay within 5–95 %")

    def frequency_ratio(self) -> float:
        """Ratio to the played note's frequency, combining octave and detune."""
        return 2.0 ** (self.octave + self.detune_cents / 1200.0)


@dataclass(frozen=True, slots=True)
class Filter:
    mode: FilterMode = FilterMode.LOW_PASS
    cutoff_hz: float = 2_400.0
    resonance: float = 0.2
    key_tracking: float = 0.5
    envelope: Envelope = field(default_factory=lambda: Envelope(0.002, 0.6, 0.1, 0.5))
    envelope_amount: float = 0.35

    def __post_init__(self) -> None:
        if not 20.0 <= self.cutoff_hz <= 20_000.0:
            raise PatchError(f"cutoff {self.cutoff_hz} Hz is outside the audible range")
        object.__setattr__(self, "resonance", _clamp(self.resonance, 0.0, 1.0))


class Route(NamedTuple):
    """One modulation routing: a source drives a destination by a signed amount."""

    source: str
    destination: str
    amount: float


@dataclass(frozen=True, slots=True)
class Patch:
    name: str
    oscillators: tuple[Oscillator, ...] = (Oscillator(), Oscillator(detune_cents=7.0))
    filter: Filter = Filter()
    amp: Envelope = Envelope()
    routes: tuple[Route, ...] = ()
    tags: frozenset[str] = frozenset()

    def __post_init__(self) -> None:
        if not self.name.strip():
            raise PatchError("a patch needs a name")
        if not 1 <= len(self.oscillators) <= 3:
            raise PatchError("between one and three oscillators")
        seen: set[tuple[str, str]] = set()
        for route in self.routes:
            key = (route.source, route.destination)
            if key in seen:
                raise PatchError(f"duplicate route {route.source} → {route.destination}")
            seen.add(key)

    def renamed(self, name: str) -> Self:
        return replace(self, name=name)

    def with_tag(self, *tags: str) -> Self:
        return replace(self, tags=self.tags | {t.lower() for t in tags})

    def total_level(self) -> float:
        return sum(o.level for o in self.oscillators)


def morph(a: Patch, b: Patch, t: float) -> Patch:
    """Blend two patches. ``t=0`` is *a*, ``t=1`` is *b*.

    Continuous parameters interpolate (times on a log curve); discrete ones,
    such as waveforms and filter modes, switch at the midpoint. Routes present
    in only one patch fade in or out with their amount.
    """
    if not 0.0 <= t <= 1.0:
        raise ValueError("t must be within 0..1")
    if len(a.oscillators) != len(b.oscillators):
        raise PatchError("can only morph patches with the same number of oscillators")

    pick = (lambda x, y: x) if t < 0.5 else (lambda x, y: y)

    oscillators = tuple(
        Oscillator(
            waveform=pick(oa.waveform, ob.waveform),
            octave=pick(oa.octave, ob.octave),
            detune_cents=_lerp(oa.detune_cents, ob.detune_cents, t),
            level=_lerp(oa.level, ob.level, t),
            pulse_width=_lerp(oa.pulse_width, ob.pulse_width, t),
        )
        for oa, ob in zip(a.oscillators, b.oscillators, strict=True)
    )

    filt = Filter(
        mode=pick(a.filter.mode, b.filter.mode),
        cutoff_hz=_log_lerp(a.filter.cutoff_hz, b.filter.cutoff_hz, t),
        resonance=_lerp(a.filter.resonance, b.filter.resonance, t),
        key_tracking=_lerp(a.filter.key_tracking, b.filter.key_tracking, t),
        envelope=a.filter.envelope.blend(b.filter.envelope, t),
        envelope_amount=_lerp(a.filter.envelope_amount, b.filter.envelope_amount, t),
    )

    routes_a = {(r.source, r.destination): r.amount for r in a.routes}
    routes_b = {(r.source, r.destination): r.amount for r in b.routes}
    routes = tuple(
        Route(src, dst, _lerp(routes_a.get((src, dst), 0.0), routes_b.get((src, dst), 0.0), t))
        for src, dst in sorted(routes_a.keys() | routes_b.keys())
    )

    return Patch(
        name=f"{a.name} ⟷ {b.name} @{t:.2f}",
        oscillators=oscillators,
        filter=filt,
        amp=a.amp.blend(b.amp, t),
        routes=tuple(r for r in routes if abs(r.amount) > 1e-6),
        tags=a.tags & b.tags,
    )


class Change(NamedTuple):
    path: str
    before: object
    after: object

    def __str__(self) -> str:
        return f"{self.path}: {self.before!r} → {self.after!r}"


def _flatten(prefix: str, value: object) -> Iterator[tuple[str, object]]:
    if hasattr(value, "__dataclass_fields__"):
        for name in value.__dataclass_fields__:  # type: ignore[attr-defined]
            yield from _flatten(f"{prefix}.{name}" if prefix else name, getattr(value, name))
    elif isinstance(value, tuple) and value and isinstance(value[0], Route):
        for route in value:
            yield f"{prefix}[{route.source}→{route.destination}]", round(route.amount, 4)
    elif isinstance(value, tuple):
        for i, item in enumerate(value):
            yield from _flatten(f"{prefix}[{i}]", item)
    elif isinstance(value, Enum):
        yield prefix, value.name.lower()
    elif isinstance(value, frozenset):
        yield prefix, ",".join(sorted(value))
    elif isinstance(value, float):
        yield prefix, round(value, 4)
    else:
        yield prefix, value


def diff(a: Patch, b: Patch) -> list[Change]:
    """Every parameter that differs between two patches, in a stable order."""
    left, right = dict(_flatten("", a)), dict(_flatten("", b))
    return [
        Change(key, left.get(key), right.get(key))
        for key in sorted(left.keys() | right.keys())
        if left.get(key) != right.get(key)
    ]


def dumps(patch: Patch) -> str:
    """Serialise to a line-oriented ``key = value`` text that diffs cleanly."""
    lines = [f"# halcyon patch v{FORMAT_VERSION}"]
    lines.extend(f"{key} = {value}" for key, value in _flatten("", patch))
    return "\n".join(lines) + "\n"


def loads(text: str, defaults: Mapping[str, object] | None = None) -> dict[str, str]:
    """Parse the text form back into a flat mapping.

    Rebuilding a :class:`Patch` from the mapping is left to the caller, who
    knows which format version it is migrating from.
    """
    out: dict[str, str] = {k: str(v) for k, v in (defaults or {}).items()}
    for number, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        key, sep, value = line.partition("=")
        if not sep:
            raise PatchError(f"line {number}: expected 'key = value', got {raw!r}")
        out[key.strip()] = value.strip()
    return out


def library_summary(patches: Iterable[Patch]) -> str:
    rows = sorted(patches, key=lambda p: p.name.casefold())
    width = max((len(p.name) for p in rows), default=4)
    return "\n".join(
        f"{p.name:<{width}}  {len(p.oscillators)} osc  {p.filter.mode.value:>5}  "
        f"{p.filter.cutoff_hz:>7.0f} Hz  {' '.join(sorted(p.tags))}"
        for p in rows
    )


if __name__ == "__main__":
    glass = Patch(
        "Glass Harbour",
        oscillators=(Oscillator(Waveform.TRIANGLE), Oscillator(Waveform.SINE, octave=1, level=0.4)),
        filter=Filter(cutoff_hz=5_200, resonance=0.1),
        amp=Envelope(attack=0.02, decay=1.2, sustain=0.3, release=2.5),
        routes=(Route("lfo1", "osc2.level", 0.15),),
    ).with_tag("pad", "bright")

    growl = Patch(
        "Low Growl",
        oscillators=(Oscillator(Waveform.SAW, octave=-1), Oscillator(Waveform.SQUARE, octave=-1, pulse_width=0.3)),
        filter=Filter(cutoff_hz=380, resonance=0.65, envelope_amount=0.8),
        amp=Envelope(attack=0.001, decay=0.3, sustain=0.9, release=0.12),
        routes=(Route("velocity", "filter.cutoff", 0.5), Route("lfo1", "osc2.level", -0.05)),
    ).with_tag("bass", "dark")

    halfway = morph(glass, growl, 0.5)
    print(library_summary([glass, growl, halfway]))
    print()
    for change in diff(glass, growl)[:8]:
        print(change)
