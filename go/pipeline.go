// Command pipeline fetches, verifies and indexes a batch of acquirer files for
// Meridian Payments' settlement service.
//
// It is built as three bounded stages joined by channels:
//
//	fetch (4 workers) -> verify (GOMAXPROCS workers) -> index (1 writer)
//
// A single context carries cancellation through every stage: the first fatal
// error, a SIGINT, or the overall deadline stops all of them, and every
// goroutine is joined before main returns. Nothing is buffered without bound,
// so a slow writer applies back-pressure all the way to the fetchers.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"math/rand/v2"
	"os"
	"os/signal"
	"runtime"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// File is one acquirer settlement file as it moves through the pipeline.
type File struct {
	Name     string
	Acquirer string
	Body     []byte
	Digest   string
	Lines    int
	Fetched  time.Duration
	Attempts int
}

// ErrCorrupt marks a file whose checksum trailer does not match its body.
// It is not fatal: the file is quarantined and the batch carries on.
var ErrCorrupt = errors.New("checksum mismatch")

// Fetcher abstracts the transport so the pipeline can be run without a
// network. The real service uses SFTP; this file ships a simulated one.
type Fetcher interface {
	Fetch(ctx context.Context, name string) ([]byte, error)
}

// Stats are updated from many goroutines, so every field is atomic.
type Stats struct {
	Fetched     atomic.Int64
	Verified    atomic.Int64
	Quarantined atomic.Int64
	Retries     atomic.Int64
	Bytes       atomic.Int64
}

// Pipeline wires the stages together.
type Pipeline struct {
	Fetcher      Fetcher
	FetchWorkers int
	MaxAttempts  int
	Log          *slog.Logger
	Stats        Stats
}

// Run processes names and returns the indexed files in name order. It returns
// early with the first fatal error, after every goroutine has stopped.
func (p *Pipeline) Run(ctx context.Context, names []string) ([]File, error) {
	ctx, cancel := context.WithCancelCause(ctx)
	defer cancel(nil)

	fetched := p.fetchStage(ctx, cancel, names)
	verified := p.verifyStage(ctx, fetched)
	index := p.indexStage(verified)

	files := <-index
	if err := context.Cause(ctx); err != nil && !errors.Is(err, context.Canceled) {
		return files, err
	}
	return files, ctx.Err()
}

// fetchStage feeds names to a fixed pool of fetchers, retrying transient
// failures with jittered exponential backoff.
func (p *Pipeline) fetchStage(ctx context.Context, fail context.CancelCauseFunc, names []string) <-chan File {
	jobs := make(chan string)
	out := make(chan File, p.FetchWorkers)

	go func() {
		defer close(jobs)
		for _, n := range names {
			select {
			case jobs <- n:
			case <-ctx.Done():
				return
			}
		}
	}()

	var wg sync.WaitGroup
	for range p.FetchWorkers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for name := range jobs {
				f, err := p.fetchWithRetry(ctx, name)
				if err != nil {
					if ctx.Err() == nil {
						fail(fmt.Errorf("fetch %s: %w", name, err))
					}
					return
				}
				select {
				case out <- f:
				case <-ctx.Done():
					return
				}
			}
		}()
	}

	go func() {
		wg.Wait()
		close(out)
	}()
	return out
}

func (p *Pipeline) fetchWithRetry(ctx context.Context, name string) (File, error) {
	backoff := 50 * time.Millisecond
	for attempt := 1; ; attempt++ {
		start := time.Now()
		body, err := p.Fetcher.Fetch(ctx, name)
		if err == nil {
			p.Stats.Fetched.Add(1)
			p.Stats.Bytes.Add(int64(len(body)))
			return File{
				Name:     name,
				Acquirer: strings.SplitN(name, "-", 2)[0],
				Body:     body,
				Fetched:  time.Since(start),
				Attempts: attempt,
			}, nil
		}
		if attempt >= p.MaxAttempts || ctx.Err() != nil {
			return File{}, err
		}

		p.Stats.Retries.Add(1)
		wait := backoff + rand.N(backoff/2)
		p.Log.Warn("fetch failed, retrying", "file", name, "attempt", attempt, "wait", wait, "err", err)

		timer := time.NewTimer(wait)
		select {
		case <-timer.C:
		case <-ctx.Done():
			timer.Stop()
			return File{}, ctx.Err()
		}
		backoff *= 2
	}
}

// verifyStage checks each file's trailer against a SHA-256 of its body.
// Corrupt files are logged and dropped rather than failing the batch.
func (p *Pipeline) verifyStage(ctx context.Context, in <-chan File) <-chan File {
	out := make(chan File)
	workers := runtime.GOMAXPROCS(0)

	var wg sync.WaitGroup
	for range workers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for f := range in {
				if err := verify(&f); err != nil {
					p.Stats.Quarantined.Add(1)
					p.Log.Error("quarantined", "file", f.Name, "err", err)
					continue
				}
				p.Stats.Verified.Add(1)
				select {
				case out <- f:
				case <-ctx.Done():
					return
				}
			}
		}()
	}

	go func() {
		wg.Wait()
		close(out)
	}()
	return out
}

func verify(f *File) error {
	body := string(f.Body)
	cut := strings.LastIndex(body, "\n#sha256:")
	if cut < 0 {
		return fmt.Errorf("%w: no trailer", ErrCorrupt)
	}
	content, trailer := body[:cut], strings.TrimSpace(body[cut+len("\n#sha256:"):])

	sum := sha256.Sum256([]byte(content))
	if got := hex.EncodeToString(sum[:]); got != trailer {
		return fmt.Errorf("%w: want %.12s, got %.12s", ErrCorrupt, trailer, got)
	}
	f.Digest = trailer
	f.Lines = strings.Count(content, "\n") + 1
	return nil
}

// indexStage is the single writer. It drains its input completely, even after
// cancellation, so upstream senders are never left blocked.
func (p *Pipeline) indexStage(in <-chan File) <-chan []File {
	done := make(chan []File, 1)
	go func() {
		var files []File
		for f := range in {
			f.Body = nil // the index keeps metadata only
			files = append(files, f)
		}
		sort.Slice(files, func(i, j int) bool { return files[i].Name < files[j].Name })
		done <- files
	}()
	return done
}

// ---------------------------------------------------------------------------
// A simulated transport: realistic latency, occasional transient failures and
// one deliberately corrupt file.
// ---------------------------------------------------------------------------

type simulatedSFTP struct {
	mu       sync.Mutex
	failures map[string]int
}

var errTransient = errors.New("connection reset by peer")

func (s *simulatedSFTP) Fetch(ctx context.Context, name string) ([]byte, error) {
	select {
	case <-time.After(time.Duration(20+rand.IntN(120)) * time.Millisecond):
	case <-ctx.Done():
		return nil, ctx.Err()
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	if s.failures[name] > 0 {
		s.failures[name]--
		return nil, errTransient
	}

	var b strings.Builder
	rows := 50 + rand.IntN(400)
	fmt.Fprintf(&b, "acquirer_ref,payment_id,gross,currency,value_date")
	for i := range rows {
		fmt.Fprintf(&b, "\nACQ-%06d,pay_%07x,%d.%02d,EUR,2026-03-14", i, rand.IntN(1<<28), rand.IntN(900), rand.IntN(100))
	}
	content := b.String()
	sum := sha256.Sum256([]byte(content))
	trailer := hex.EncodeToString(sum[:])
	if strings.Contains(name, "0007") {
		trailer = strings.Repeat("0", 64) // corrupted in transit
	}
	return []byte(content + "\n#sha256:" + trailer), nil
}

func main() {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	var names []string
	for _, acq := range []string{"northbank", "kestrel", "solent"} {
		for range 8 {
			names = append(names, fmt.Sprintf("%s-20260314-%04d.csv", acq, len(names)+1))
		}
	}

	p := &Pipeline{
		Fetcher: &simulatedSFTP{failures: map[string]int{
			names[2]: 1, names[11]: 2, names[19]: 1,
		}},
		FetchWorkers: 4,
		MaxAttempts:  4,
		Log:          logger,
	}

	start := time.Now()
	files, err := p.Run(ctx, names)
	if err != nil {
		logger.Error("pipeline stopped", "err", err)
		os.Exit(1)
	}

	fmt.Printf("%-28s %-10s %6s %8s %s\n", "FILE", "ACQUIRER", "LINES", "TRIES", "SHA-256")
	for _, f := range files {
		fmt.Printf("%-28s %-10s %6d %8d %.16s\n", f.Name, f.Acquirer, f.Lines, f.Attempts, f.Digest)
	}
	fmt.Printf("\n%d fetched, %d verified, %d quarantined, %d retries, %.1f KiB in %s\n",
		p.Stats.Fetched.Load(), p.Stats.Verified.Load(), p.Stats.Quarantined.Load(),
		p.Stats.Retries.Load(), float64(p.Stats.Bytes.Load())/1024, time.Since(start).Round(time.Millisecond))
}
