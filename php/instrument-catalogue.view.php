<?php
/**
 * Catalogue page for Halcyon Instruments.
 *
 * A plain PHP view: the controller hands it $instruments, $filter and $page,
 * and this file only escapes and arranges. No queries, no business rules.
 *
 * @var list<array{
 *     sku: string, name: string, family: string, voices: int,
 *     price_minor: int, in_stock: int, tags: list<string>, released: string
 * }> $instruments
 * @var array{family: ?string, search: string, sort: string} $filter
 * @var array{current: int, per_page: int, total: int} $page
 */

declare(strict_types=1);

$e = static fn (?string $value): string => htmlspecialchars($value ?? '', ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');

$price = static function (int $minor): string {
    return '€' . number_format($minor / 100, 2, '.', ' ');
};

$stockLabel = static fn (int $count): array => match (true) {
    $count === 0 => ['Sold out', 'stock--none'],
    $count < 5   => ["Only {$count} left", 'stock--low'],
    default      => ['In stock', 'stock--ok'],
};

$families = [
    'mono'     => 'Monophonic',
    'poly'     => 'Polyphonic',
    'drum'     => 'Drum machines',
    'modular'  => 'Eurorack modules',
    'effects'  => 'Effects',
];

$sorts = [
    'newest'     => 'Newest first',
    'price-asc'  => 'Price, low to high',
    'price-desc' => 'Price, high to low',
    'voices'     => 'Most voices',
];

$query = static function (array $overrides) use ($filter): string {
    $params = array_filter(
        array_merge($filter, $overrides),
        static fn ($v) => $v !== null && $v !== '',
    );
    return '?' . http_build_query($params);
};

$pages = max(1, (int) ceil($page['total'] / max(1, $page['per_page'])));
$first = ($page['current'] - 1) * $page['per_page'] + 1;
$last  = min($page['total'], $page['current'] * $page['per_page']);
?>
<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Instruments · Halcyon Instruments</title>
    <link rel="stylesheet" href="/assets/catalogue.css">
</head>
<body class="catalogue">

<header class="masthead">
    <a class="masthead__brand" href="/">Halcyon Instruments</a>
    <nav class="masthead__nav" aria-label="Primary">
        <a href="/instruments" aria-current="page">Instruments</a>
        <a href="/patches">Patch library</a>
        <a href="/support">Support</a>
    </nav>
</header>

<main class="catalogue__body">
    <aside class="filters" aria-labelledby="filters-title">
        <h2 id="filters-title">Browse</h2>

        <form method="get" action="/instruments" class="filters__search">
            <label for="q">Search</label>
            <input id="q" name="search" type="search" value="<?= $e($filter['search']) ?>"
                   placeholder="Oscillator, filter, sequencer…">
            <?php if ($filter['family'] !== null): ?>
                <input type="hidden" name="family" value="<?= $e($filter['family']) ?>">
            <?php endif ?>
            <button type="submit">Go</button>
        </form>

        <ul class="filters__families">
            <li>
                <a href="<?= $e($query(['family' => null, 'page' => null])) ?>"
                   <?= $filter['family'] === null ? 'aria-current="true"' : '' ?>>All instruments</a>
            </li>
            <?php foreach ($families as $key => $label): ?>
                <li>
                    <a href="<?= $e($query(['family' => $key, 'page' => null])) ?>"
                       <?= $filter['family'] === $key ? 'aria-current="true"' : '' ?>>
                        <?= $e($label) ?>
                    </a>
                </li>
            <?php endforeach ?>
        </ul>
    </aside>

    <section class="results" aria-live="polite">
        <div class="results__bar">
            <?php if ($page['total'] === 0): ?>
                <p>No instruments match <strong><?= $e($filter['search']) ?></strong>.</p>
            <?php else: ?>
                <p>Showing <?= $first ?>–<?= $last ?> of <?= number_format($page['total']) ?></p>
            <?php endif ?>

            <form method="get" class="results__sort">
                <label for="sort">Sort</label>
                <select id="sort" name="sort" onchange="this.form.submit()">
                    <?php foreach ($sorts as $key => $label): ?>
                        <option value="<?= $e($key) ?>" <?= $filter['sort'] === $key ? 'selected' : '' ?>>
                            <?= $e($label) ?>
                        </option>
                    <?php endforeach ?>
                </select>
            </form>
        </div>

        <ol class="grid">
            <?php foreach ($instruments as $item): ?>
                <?php [$stockText, $stockClass] = $stockLabel($item['in_stock']); ?>
                <li class="card">
                    <a class="card__link" href="/instruments/<?= rawurlencode($item['sku']) ?>">
                        <img class="card__image"
                             src="/media/instruments/<?= rawurlencode($item['sku']) ?>-640.webp"
                             srcset="/media/instruments/<?= rawurlencode($item['sku']) ?>-640.webp 640w,
                                     /media/instruments/<?= rawurlencode($item['sku']) ?>-1280.webp 1280w"
                             sizes="(min-width: 60rem) 20rem, 90vw"
                             width="640" height="400" loading="lazy"
                             alt="<?= $e($item['name']) ?>, front panel">
                        <h3 class="card__name"><?= $e($item['name']) ?></h3>
                    </a>

                    <dl class="card__specs">
                        <dt>Family</dt>
                        <dd><?= $e($families[$item['family']] ?? ucfirst($item['family'])) ?></dd>
                        <dt>Voices</dt>
                        <dd><?= $item['voices'] === 1 ? 'Mono' : $item['voices'] ?></dd>
                        <dt>Released</dt>
                        <dd><time datetime="<?= $e($item['released']) ?>"><?= $e(date('F Y', strtotime($item['released']))) ?></time></dd>
                    </dl>

                    <?php if ($item['tags'] !== []): ?>
                        <ul class="card__tags">
                            <?php foreach (array_slice($item['tags'], 0, 4) as $tag): ?>
                                <li><?= $e($tag) ?></li>
                            <?php endforeach ?>
                        </ul>
                    <?php endif ?>

                    <footer class="card__footer">
                        <span class="card__price"><?= $e($price($item['price_minor'])) ?></span>
                        <span class="stock <?= $stockClass ?>"><?= $e($stockText) ?></span>
                    </footer>
                </li>
            <?php endforeach ?>
        </ol>

        <?php if ($pages > 1): ?>
            <nav class="pager" aria-label="Pages">
                <?php if ($page['current'] > 1): ?>
                    <a rel="prev" href="<?= $e($query(['page' => $page['current'] - 1])) ?>">← Previous</a>
                <?php endif ?>

                <?php for ($n = 1; $n <= $pages; $n++): ?>
                    <?php if ($n === $page['current']): ?>
                        <span aria-current="page"><?= $n ?></span>
                    <?php elseif ($n === 1 || $n === $pages || abs($n - $page['current']) <= 2): ?>
                        <a href="<?= $e($query(['page' => $n])) ?>"><?= $n ?></a>
                    <?php elseif (abs($n - $page['current']) === 3): ?>
                        <span class="pager__gap">…</span>
                    <?php endif ?>
                <?php endfor ?>

                <?php if ($page['current'] < $pages): ?>
                    <a rel="next" href="<?= $e($query(['page' => $page['current'] + 1])) ?>">Next →</a>
                <?php endif ?>
            </nav>
        <?php endif ?>
    </section>
</main>

<footer class="colophon">
    <p>Every Halcyon instrument is assembled and calibrated by hand. Prices include VAT.</p>
</footer>

</body>
</html>
