// Command route picks the cheapest way to move money between currencies
// across a graph of FX corridors, using Dijkstra's algorithm on a generic
// binary heap.
//
// Each corridor has a rate, a percentage spread and a fixed fee. The cost
// of a path is not additive in the source amount (fixed fees matter more on
// small transfers), so the search runs on the amount actually delivered:
// a path is better if it delivers more of the target currency.
package main

import (
	"cmp"
	"fmt"
	"strings"
)

// ---------------------------------------------------------------------------
// A small generic binary heap.
// ---------------------------------------------------------------------------

type Heap[T any] struct {
	items []T
	less  func(a, b T) bool
}

func NewHeap[T any](less func(a, b T) bool) *Heap[T] { return &Heap[T]{less: less} }

func (h *Heap[T]) Len() int { return len(h.items) }

func (h *Heap[T]) Push(v T) {
	h.items = append(h.items, v)
	for i := len(h.items) - 1; i > 0; {
		parent := (i - 1) / 2
		if !h.less(h.items[i], h.items[parent]) {
			break
		}
		h.items[i], h.items[parent] = h.items[parent], h.items[i]
		i = parent
	}
}

func (h *Heap[T]) Pop() T {
	top := h.items[0]
	last := len(h.items) - 1
	h.items[0] = h.items[last]
	h.items = h.items[:last]

	for i := 0; ; {
		l, r, best := 2*i+1, 2*i+2, i
		if l < last && h.less(h.items[l], h.items[best]) {
			best = l
		}
		if r < last && h.less(h.items[r], h.items[best]) {
			best = r
		}
		if best == i {
			break
		}
		h.items[i], h.items[best] = h.items[best], h.items[i]
		i = best
	}
	return top
}

// ---------------------------------------------------------------------------
// Corridors and routing.
// ---------------------------------------------------------------------------

type Currency string

type Corridor struct {
	From, To Currency
	Via      string  // the liquidity provider
	Rate     float64 // units of To per unit of From, mid-market
	SpreadBp float64 // basis points taken off the rate
	FixedFee float64 // in units of From, charged before conversion
}

// Deliver applies the corridor to an amount; ok is false if the fee eats it.
func (c Corridor) Deliver(amount float64) (out float64, ok bool) {
	net := amount - c.FixedFee
	if net <= 0 {
		return 0, false
	}
	return net * c.Rate * (1 - c.SpreadBp/10_000), true
}

type Graph map[Currency][]Corridor

func (g Graph) Add(c Corridor) { g[c.From] = append(g[c.From], c) }

type Route struct {
	Hops      []Corridor
	Delivered float64
}

func (r Route) String() string {
	if len(r.Hops) == 0 {
		return "(no route)"
	}
	var b strings.Builder
	b.WriteString(string(r.Hops[0].From))
	for _, h := range r.Hops {
		fmt.Fprintf(&b, " -[%s]-> %s", h.Via, h.To)
	}
	return b.String()
}

// Best finds the route from src to dst that delivers the most, using at most
// maxHops corridors.
//
// Amounts at different nodes are in different currencies, so the queue is
// ordered by what each amount is worth back in src at mid-market: the
// amount divided by the product of mid rates along its path. Spreads and
// fees only ever lose value, so that worth never rises along an edge, which
// is the property Dijkstra's greedy choice needs.
func (g Graph) Best(src, dst Currency, amount float64, maxHops int) (Route, bool) {
	type state struct {
		at     Currency
		amount float64 // in units of `at`
		mid    float64 // product of mid-market rates from src to `at`
		hops   []Corridor
	}
	worth := func(s state) float64 { return s.amount / s.mid }

	best := map[Currency]float64{src: amount}
	pq := NewHeap(func(a, b state) bool { return worth(a) > worth(b) }) // max-heap
	pq.Push(state{at: src, amount: amount, mid: 1})

	for pq.Len() > 0 {
		s := pq.Pop()
		if s.at == dst {
			return Route{Hops: s.hops, Delivered: s.amount}, true
		}
		if s.amount < best[s.at] || len(s.hops) == maxHops {
			continue // a better way here was already expanded, or out of hops
		}
		for _, c := range g[s.at] {
			out, ok := c.Deliver(s.amount)
			if !ok || out <= best[c.To] {
				continue
			}
			best[c.To] = out
			hops := append(append(make([]Corridor, 0, len(s.hops)+1), s.hops...), c)
			pq.Push(state{at: c.To, amount: out, mid: s.mid * c.Rate, hops: hops})
		}
	}
	return Route{}, false
}

// ---------------------------------------------------------------------------

func main() {
	g := Graph{}
	for _, c := range []Corridor{
		{"EUR", "USD", "Kestrel FX", 1.0870, 18, 0.40},
		{"EUR", "GBP", "Kestrel FX", 0.8540, 15, 0.40},
		{"EUR", "SEK", "Northbank", 11.320, 22, 1.50},
		{"EUR", "PLN", "Northbank", 4.3110, 30, 0.90},
		{"GBP", "USD", "Solent Markets", 1.2730, 9, 0.25},
		{"USD", "JPY", "Solent Markets", 149.80, 12, 0.30},
		{"EUR", "JPY", "Kestrel FX", 162.83, 55, 2.00},
		{"SEK", "NOK", "Northbank", 1.0150, 8, 2.50},
		{"EUR", "NOK", "Kestrel FX", 11.490, 48, 1.00},
		{"USD", "BRL", "Solent Markets", 5.0100, 40, 1.10},
		{"EUR", "BRL", "Kestrel FX", 5.4460, 95, 3.00},
		{"GBP", "SEK", "Solent Markets", 13.255, 14, 0.80},
	} {
		g.Add(c)
	}

	type query struct {
		to     Currency
		amount float64
	}
	queries := []query{{"JPY", 25}, {"JPY", 25_000}, {"NOK", 40}, {"NOK", 40_000}, {"BRL", 900}, {"CHF", 100}}

	fmt.Printf("%-6s %10s  %-14s  %s\n", "TO", "EUR IN", "DELIVERED", "ROUTE")
	for _, q := range queries {
		r, ok := g.Best("EUR", q.to, q.amount, 3)
		delivered := "-"
		if ok {
			delivered = fmt.Sprintf("%.2f %s", r.Delivered, q.to)
		}
		fmt.Printf("%-6s %10.2f  %-14s  %s\n", q.to, q.amount, delivered, r)
	}

	// The heap is generic; a quick sanity check with another ordering.
	h := NewHeap(func(a, b string) bool { return cmp.Less(a, b) })
	for _, s := range []string{"solent", "kestrel", "northbank"} {
		h.Push(s)
	}
	fmt.Println("\nproviders:", h.Pop(), h.Pop(), h.Pop())
}
