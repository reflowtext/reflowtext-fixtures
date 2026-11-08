/**
 * dom-kit: a handful of typed DOM helpers for pages that do not need a framework.
 *
 * - `h()` builds elements with typed attributes, properties and listeners.
 * - `on()` and `delegate()` attach listeners and return a disposer.
 * - `Disposables` collects disposers so a widget can tear itself down.
 * - `trapFocus()`, `debounce()`, `whenVisible()` cover the usual chores.
 *
 * Everything returns a cleanup function; nothing leaks after `dispose()`.
 */

export type Dispose = () => void;

// ------------------------------------------------------------ building --

type Child = Node | string | number | false | null | undefined | ReadonlyArray<Child>;

type EventHandlers<K extends keyof HTMLElementTagNameMap> = {
  [E in keyof HTMLElementEventMap as `on${Capitalize<E>}`]?: (
    this: HTMLElementTagNameMap[K],
    event: HTMLElementEventMap[E],
  ) => void;
};

type Props<K extends keyof HTMLElementTagNameMap> = Partial<
  Omit<HTMLElementTagNameMap[K], "style" | "dataset" | keyof EventHandlers<K>>
> &
  EventHandlers<K> & {
    style?: Partial<Record<keyof CSSStyleDeclaration | `--${string}`, string>>;
    dataset?: Record<string, string>;
    attrs?: Record<string, string | boolean>;
    ref?: (el: HTMLElementTagNameMap[K]) => void;
  };

function append(parent: Node, child: Child): void {
  if (child === false || child === null || child === undefined) return;
  if (Array.isArray(child)) {
    for (const c of child as ReadonlyArray<Child>) append(parent, c);
    return;
  }
  parent.appendChild(
    child instanceof Node ? child : document.createTextNode(String(child)),
  );
}

/**
 * Create an element.
 *
 *     h("button", { type: "button", className: "primary", onClick: save }, "Save")
 */
export function h<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  props: Props<K> | null = null,
  ...children: Child[]
): HTMLElementTagNameMap[K] {
  const el = document.createElement(tag);

  if (props) {
    for (const [key, value] of Object.entries(props) as Array<[string, unknown]>) {
      if (value === undefined) continue;

      if (key === "style") {
        for (const [prop, v] of Object.entries(value as Record<string, string>)) {
          if (prop.startsWith("--")) el.style.setProperty(prop, v);
          else (el.style as unknown as Record<string, string>)[prop] = v;
        }
      } else if (key === "dataset") {
        Object.assign(el.dataset, value);
      } else if (key === "attrs") {
        for (const [name, v] of Object.entries(value as Record<string, string | boolean>)) {
          if (v === false) el.removeAttribute(name);
          else el.setAttribute(name, v === true ? "" : v);
        }
      } else if (key === "ref") {
        continue; // called last, once the element is complete
      } else if (/^on[A-Z]/.test(key) && typeof value === "function") {
        el.addEventListener(key.slice(2).toLowerCase(), value as EventListener);
      } else {
        (el as unknown as Record<string, unknown>)[key] = value;
      }
    }
  }

  append(el, children);
  props?.ref?.(el);
  return el;
}

/** Replace an element's children in one operation. */
export function render(target: Element, ...children: Child[]): void {
  const fragment = document.createDocumentFragment();
  append(fragment, children);
  target.replaceChildren(fragment);
}

// ----------------------------------------------------------- listening --

export function on<T extends EventTarget, K extends keyof HTMLElementEventMap>(
  target: T,
  type: K,
  listener: (event: HTMLElementEventMap[K]) => void,
  options?: AddEventListenerOptions,
): Dispose {
  target.addEventListener(type, listener as EventListener, options);
  return () => target.removeEventListener(type, listener as EventListener, options);
}

/**
 * One listener on a container for many children, matched by selector.
 * Works for children added later, which is the point.
 */
export function delegate<K extends keyof HTMLElementEventMap, M extends Element = Element>(
  root: Element | Document,
  type: K,
  selector: string,
  listener: (event: HTMLElementEventMap[K], match: M) => void,
): Dispose {
  return on(root as HTMLElement, type, (event) => {
    const origin = event.target;
    if (!(origin instanceof Element)) return;
    const match = origin.closest<M>(selector as never);
    if (match && (root === document || (root as Element).contains(match))) {
      listener(event, match as M);
    }
  });
}

export class Disposables {
  #items: Dispose[] = [];

  add(...items: Dispose[]): this {
    this.#items.push(...items);
    return this;
  }

  /** Run every disposer once, newest first, even if one throws. */
  dispose(): void {
    const errors: unknown[] = [];
    for (const fn of this.#items.splice(0).reverse()) {
      try {
        fn();
      } catch (error) {
        errors.push(error);
      }
    }
    if (errors.length) throw new AggregateError(errors, "one or more disposers failed");
  }
}

// --------------------------------------------------------------- timing --

export interface Debounced<A extends unknown[]> {
  (...args: A): void;
  flush(): void;
  cancel(): void;
}

export function debounce<A extends unknown[]>(fn: (...args: A) => void, waitMs: number): Debounced<A> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  let pending: A | undefined;

  const run = () => {
    timer = undefined;
    if (pending) {
      const args = pending;
      pending = undefined;
      fn(...args);
    }
  };

  const debounced = ((...args: A) => {
    pending = args;
    if (timer !== undefined) clearTimeout(timer);
    timer = setTimeout(run, waitMs);
  }) as Debounced<A>;

  debounced.flush = () => {
    if (timer !== undefined) clearTimeout(timer);
    run();
  };
  debounced.cancel = () => {
    if (timer !== undefined) clearTimeout(timer);
    timer = undefined;
    pending = undefined;
  };
  return debounced;
}

/** Call `fn` once, the first time `el` scrolls into view. */
export function whenVisible(el: Element, fn: () => void, rootMargin = "200px"): Dispose {
  const observer = new IntersectionObserver(
    (entries) => {
      if (entries.some((entry) => entry.isIntersecting)) {
        observer.disconnect();
        fn();
      }
    },
    { rootMargin },
  );
  observer.observe(el);
  return () => observer.disconnect();
}

// ---------------------------------------------------------------- focus --

const FOCUSABLE = [
  "a[href]",
  "area[href]",
  "button:not([disabled])",
  "input:not([disabled]):not([type=hidden])",
  "select:not([disabled])",
  "textarea:not([disabled])",
  "[tabindex]:not([tabindex='-1'])",
  "[contenteditable='true']",
].join(",");

export function focusable(root: ParentNode): HTMLElement[] {
  return Array.from(root.querySelectorAll<HTMLElement>(FOCUSABLE)).filter(
    (el) => !el.closest("[inert]") && el.getClientRects().length > 0,
  );
}

/**
 * Keep Tab and Shift+Tab inside `container` (a dialog, a sheet).
 * Returns a disposer that also restores focus to where it was.
 */
export function trapFocus(container: HTMLElement, onEscape?: () => void): Dispose {
  const previouslyFocused = document.activeElement as HTMLElement | null;
  (focusable(container)[0] ?? container).focus();

  const stop = on(container, "keydown", (event) => {
    if (event.key === "Escape" && onEscape) {
      event.preventDefault();
      onEscape();
      return;
    }
    if (event.key !== "Tab") return;

    const items = focusable(container);
    if (items.length === 0) {
      event.preventDefault();
      return;
    }
    const first = items[0]!;
    const last = items[items.length - 1]!;
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  });

  return () => {
    stop();
    previouslyFocused?.focus?.();
  };
}

// --------------------------------------------------------------- example --

/**
 * A filterable list of Halcyon Instruments patches, built with the helpers
 * above. Returns a disposer that removes every listener it added.
 */
export function mountPatchFilter(root: HTMLElement, names: readonly string[]): Dispose {
  const bin = new Disposables();
  let list!: HTMLUListElement;
  let count!: HTMLOutputElement;

  const update = debounce((query: string) => {
    const needle = query.trim().toLocaleLowerCase();
    const shown = names.filter((n) => n.toLocaleLowerCase().includes(needle));
    render(list, shown.map((name) => h("li", { tabIndex: 0, dataset: { name } }, name)));
    count.value = `${shown.length} of ${names.length}`;
  }, 120);

  render(
    root,
    h("label", { htmlFor: "patch-filter" }, "Filter patches"),
    h("input", {
      id: "patch-filter",
      type: "search",
      autocomplete: "off",
      onInput() {
        update(this.value);
      },
    }),
    h("output", { ref: (el) => (count = el), attrs: { "aria-live": "polite" } }),
    h("ul", { className: "patch-list", ref: (el) => (list = el) }),
  );

  bin.add(
    () => update.cancel(),
    delegate<"keydown", HTMLLIElement>(root, "keydown", "li[data-name]", (event, li) => {
      if (event.key === "Enter") li.dispatchEvent(new CustomEvent("patch:choose", { bubbles: true, detail: li.dataset.name }));
    }),
  );

  update("");
  update.flush();
  return () => bin.dispose();
}
