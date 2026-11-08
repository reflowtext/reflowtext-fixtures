using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;

namespace Halcyon.Collections;

/// <summary>
/// A closed interval [<see cref="Start"/>, <see cref="End"/>] over any comparable key.
/// </summary>
public readonly record struct Interval<T>(T Start, T End) where T : IComparable<T>
{
    public bool Overlaps(Interval<T> other) =>
        Start.CompareTo(other.End) <= 0 && other.Start.CompareTo(End) <= 0;

    public bool Contains(T point) =>
        Start.CompareTo(point) <= 0 && point.CompareTo(End) <= 0;

    public override string ToString() => $"[{Start}, {End}]";
}

/// <summary>
/// An augmented red-black tree that stores intervals with associated values and
/// answers "which intervals overlap this one?" in O(log n + k).
/// </summary>
/// <remarks>
/// <para>
/// Each node is keyed by its interval's start and additionally records the
/// largest end point anywhere in its subtree (<c>MaxEnd</c>). A search can
/// then skip an entire left subtree whose <c>MaxEnd</c> lies before the
/// query, which is what makes the query output-sensitive.
/// </para>
/// <para>
/// The Halcyon sequencer uses this to find every note that sounds during a
/// given block of audio: the tree holds a few thousand notes and is queried
/// once per 64-sample block, so the query path must not allocate.
/// </para>
/// </remarks>
/// <typeparam name="TKey">The interval end-point type.</typeparam>
/// <typeparam name="TValue">The payload stored with each interval.</typeparam>
public sealed class IntervalTree<TKey, TValue> : IEnumerable<(Interval<TKey> Interval, TValue Value)>
    where TKey : IComparable<TKey>
{
    private enum Color : byte { Red, Black }

    private sealed class Node
    {
        public Interval<TKey> Interval;
        public TValue Value;
        public TKey MaxEnd;
        public Color Color = Color.Red;
        public Node? Left, Right, Parent;

        public Node(Interval<TKey> interval, TValue value)
        {
            Interval = interval;
            Value = value;
            MaxEnd = interval.End;
        }
    }

    private Node? _root;

    /// <summary>The number of intervals stored.</summary>
    public int Count { get; private set; }

    /// <summary>Adds an interval. Duplicates are allowed.</summary>
    /// <exception cref="ArgumentException">The interval ends before it starts.</exception>
    public void Add(Interval<TKey> interval, TValue value)
    {
        if (interval.Start.CompareTo(interval.End) > 0)
        {
            throw new ArgumentException($"Interval {interval} ends before it starts.", nameof(interval));
        }

        var node = new Node(interval, value);
        Node? parent = null;
        var cursor = _root;
        while (cursor is not null)
        {
            parent = cursor;
            cursor.MaxEnd = Max(cursor.MaxEnd, interval.End);
            cursor = interval.Start.CompareTo(cursor.Interval.Start) < 0 ? cursor.Left : cursor.Right;
        }

        node.Parent = parent;
        if (parent is null) _root = node;
        else if (interval.Start.CompareTo(parent.Interval.Start) < 0) parent.Left = node;
        else parent.Right = node;

        Count++;
        FixAfterInsert(node);
        Debug.Assert(_root!.Color == Color.Black);
    }

    /// <summary>
    /// Calls <paramref name="visit"/> for every stored interval overlapping
    /// <paramref name="query"/>. Does not allocate.
    /// </summary>
    public void Query(Interval<TKey> query, Action<Interval<TKey>, TValue> visit)
    {
        ArgumentNullException.ThrowIfNull(visit);
        Visit(_root, query, visit);

        static void Visit(Node? node, Interval<TKey> q, Action<Interval<TKey>, TValue> visit)
        {
            while (node is not null)
            {
                // Nothing in this subtree ends late enough to reach the query.
                if (node.MaxEnd.CompareTo(q.Start) < 0) return;

                Visit(node.Left, q, visit);

                // Everything to the right starts after this node, so if this
                // node already starts past the query, so does the right side.
                if (node.Interval.Start.CompareTo(q.End) > 0) return;

                if (node.Interval.Overlaps(q)) visit(node.Interval, node.Value);
                node = node.Right;
            }
        }
    }

    /// <summary>Returns every stored interval overlapping <paramref name="query"/>, in start order.</summary>
    public List<(Interval<TKey> Interval, TValue Value)> Overlapping(Interval<TKey> query)
    {
        var results = new List<(Interval<TKey>, TValue)>();
        Query(query, (i, v) => results.Add((i, v)));
        return results;
    }

    /// <summary>Returns every stored interval containing <paramref name="point"/>.</summary>
    public List<(Interval<TKey> Interval, TValue Value)> Stabbing(TKey point) =>
        Overlapping(new Interval<TKey>(point, point));

    /// <summary>Enumerates all intervals in order of their start point.</summary>
    public IEnumerator<(Interval<TKey> Interval, TValue Value)> GetEnumerator()
    {
        var stack = new Stack<Node>();
        var node = _root;
        while (stack.Count > 0 || node is not null)
        {
            while (node is not null)
            {
                stack.Push(node);
                node = node.Left;
            }
            node = stack.Pop();
            yield return (node.Interval, node.Value);
            node = node.Right;
        }
    }

    IEnumerator IEnumerable.GetEnumerator() => GetEnumerator();

    // ------------------------------------------------------------------
    // Red-black balancing (CLRS-style), keeping MaxEnd correct on rotation
    // ------------------------------------------------------------------

    private void FixAfterInsert(Node z)
    {
        while (z.Parent is { Color: Color.Red } parent)
        {
            var grand = parent.Parent!;
            var parentIsLeft = parent == grand.Left;
            var uncle = parentIsLeft ? grand.Right : grand.Left;

            if (uncle is { Color: Color.Red })
            {
                parent.Color = Color.Black;
                uncle.Color = Color.Black;
                grand.Color = Color.Red;
                z = grand;
                continue;
            }

            if (parentIsLeft)
            {
                if (z == parent.Right)
                {
                    z = parent;
                    RotateLeft(z);
                }
                z.Parent!.Color = Color.Black;
                grand.Color = Color.Red;
                RotateRight(grand);
            }
            else
            {
                if (z == parent.Left)
                {
                    z = parent;
                    RotateRight(z);
                }
                z.Parent!.Color = Color.Black;
                grand.Color = Color.Red;
                RotateLeft(grand);
            }
        }
        _root!.Color = Color.Black;
    }

    private void RotateLeft(Node x)
    {
        var y = x.Right!;
        x.Right = y.Left;
        if (y.Left is not null) y.Left.Parent = x;
        Replace(x, y);
        y.Left = x;
        x.Parent = y;
        Recompute(x);
        Recompute(y);
    }

    private void RotateRight(Node x)
    {
        var y = x.Left!;
        x.Left = y.Right;
        if (y.Right is not null) y.Right.Parent = x;
        Replace(x, y);
        y.Right = x;
        x.Parent = y;
        Recompute(x);
        Recompute(y);
    }

    private void Replace(Node old, Node replacement)
    {
        replacement.Parent = old.Parent;
        if (old.Parent is null) _root = replacement;
        else if (old == old.Parent.Left) old.Parent.Left = replacement;
        else old.Parent.Right = replacement;
    }

    private static void Recompute(Node n)
    {
        var max = n.Interval.End;
        if (n.Left is not null) max = Max(max, n.Left.MaxEnd);
        if (n.Right is not null) max = Max(max, n.Right.MaxEnd);
        n.MaxEnd = max;
    }

    private static TKey Max(TKey a, TKey b) => a.CompareTo(b) >= 0 ? a : b;
}

/// <summary>A tiny demonstration: which notes sound during each block?</summary>
public static class IntervalTreeDemo
{
    public static void Main()
    {
        var notes = new IntervalTree<int, string>();
        notes.Add(new(0, 479), "C3");
        notes.Add(new(240, 719), "E3");
        notes.Add(new(480, 959), "G3");
        notes.Add(new(960, 1919), "C4 (held)");
        notes.Add(new(1200, 1259), "D5 (grace)");
        notes.Add(new(1260, 1439), "C5");

        const int blockTicks = 240;
        for (var start = 0; start < 1920; start += blockTicks)
        {
            var block = new Interval<int>(start, start + blockTicks - 1);
            var sounding = notes.Overlapping(block);
            Console.WriteLine($"{block,-12} {string.Join(", ", sounding.ConvertAll(n => n.Value))}");
        }
    }
}
