<?php

use App\Models\DeviceModel;
use App\Services\ImageGenerationService;
use Illuminate\Contracts\Console\Kernel;
use Illuminate\Support\Facades\Blade;
use Illuminate\Support\Facades\Storage;
use Spatie\Browsershot\Browsershot;

require getcwd().'/vendor/autoload.php';
$app = require getcwd().'/bootstrap/app.php';
$app->make(Kernel::class)->bootstrap();

$html = Blade::render(<<<'BLADE'
<x-trmnl::screen deviceVariant="v2" scaleLevel="xxlarge">
    <style>
        .probe { box-sizing: border-box; width: 240px; height: 120px; }
        .probe table { box-sizing: border-box; width: 240px; border-collapse: collapse; table-layout: fixed; }
        .probe table, .probe tr, .probe th, .probe td { margin: 0; padding: 0; border: 0; }
        .probe tr, .probe th, .probe td { box-sizing: border-box; height: 24px; line-height: 24px; }
    </style>
    <p style="font-family: Inter">Größe Αθήνα Київ</p>
    <div class="probe">
        <table class="table" data-table-limit="true">
            <thead><tr><th>Heading</th></tr></thead>
            <tbody>
                @foreach(range(1, 6) as $row)
                    <tr id="row-{{ $row }}"><td>Row {{ $row }}</td></tr>
                @endforeach
            </tbody>
        </table>
    </div>
</x-trmnl::screen>
BLADE);

$browser = Browsershot::html($html)
    ->noSandbox()
    ->waitUntilNetworkIdle()
    ->blockDomains(['trmnl.com', 'fonts.bunny.net']);

$script = <<<'JS'
Promise.all([300,400,500,600].map(async weight => {
    const faces = await document.fonts.load(`${weight} 20px Inter`, 'Größe Αθήνα Київ');
    if (faces.length !== 3 || faces.some(face => face.status !== 'loaded')) {
        throw new Error(`Inter ${weight} did not load all language subsets`);
    }
})).then(async () => {
    await window.terminalize();
    const parent = document.querySelector('.probe');
    const table = parent.querySelector('table');
    const rows = [...table.querySelectorAll('tbody > tr[id]')];
    return JSON.stringify({
    framework: typeof window.TRMNLPaint,
    external: performance.getEntriesByType('resource')
        .map(resource => resource.name)
        .filter(url => !url.startsWith(__ASSET_BASE_URL__) && !url.startsWith('data:')),
    table: {
        fits: table.getBoundingClientRect().height <= parent.getBoundingClientRect().height + 0.01,
        visible: rows.filter(row => getComputedStyle(row).display !== 'none').map(row => row.id),
        hidden: rows.filter(row => getComputedStyle(row).display === 'none').map(row => row.id),
        labels: [...table.querySelectorAll('[data-table-overflow-label="true"]')].map(row => row.textContent.trim()),
    },
    });
})
JS;
$script = str_replace('__ASSET_BASE_URL__', json_encode(rtrim(config('app.url'), '/').'/', JSON_THROW_ON_ERROR), $script);
$result = json_decode($browser->evaluate($script), true, flags: JSON_THROW_ON_ERROR);

if ($result !== [
    'framework' => 'object',
    'external' => [],
    'table' => [
        'fits' => true,
        'visible' => ['row-1', 'row-2'],
        'hidden' => ['row-3', 'row-4', 'row-5', 'row-6'],
        'labels' => ['and 4 more'],
    ],
]) {
    throw new RuntimeException(json_encode($result, JSON_THROW_ON_ERROR));
}

$browser->windowSize(800, 480)->save('/tmp/larapaper-smoke.png');
$image = new Imagick('/tmp/larapaper-smoke.png');

if ($image->getImageWidth() !== 800 || $image->getImageHeight() !== 480) {
    throw new RuntimeException('The rendered image has incorrect dimensions');
}

$probe = Blade::render(<<<'BLADE'
<x-trmnl::screen deviceVariant="v2">
    <div style="position: absolute; top: 0; left: 0; width: 160px; height: 160px; background: var(--framework-text-primary)"></div>
</x-trmnl::screen>
BLADE);
$model = DeviceModel::query()->where('name', 'v2')->firstOrFail();
$imageId = ImageGenerationService::generateImageFromModel(markup: $probe, deviceModel: $model);
$processed = new Imagick(Storage::disk('public')->path('images/generated/'.$imageId.'.png'));
$pixel = $processed->getImagePixelColor(100, 100)->getColor();
if ([$pixel['r'], $pixel['g'], $pixel['b']] !== [0, 0, 0]) {
    throw new RuntimeException('The production renderer did not load framework colours');
}

echo "Scaled tables, local fonts, production rendering, Chromium and Imagick passed\n";
