// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Performance test for color palette widget population (issue #4396).
 *
 * Exercises the slow path reported when switching to large palettes such as
 * MunsellChart: building many ColorItem widgets and pushing them through
 * ColorPalette::set_colors() / rebuild_widgets().
 *
 * Intended to be profiled via the perf_color-palette-perf-test CTest target.
 */

#include <chrono>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <string>
#include <vector>

#include <glibmm/init.h>
#include <gtest/gtest.h>
#include <gtkmm/application.h>
#include <gtkmm/window.h>

#include "colors/color.h"
#include "ui/dialog/color-item.h"
#include "ui/dialog/global-palettes.h"
#include "ui/widget/color-palette.h"

#ifndef INKSCAPE_SHARE_DIR
#define INKSCAPE_SHARE_DIR "share"
#endif

using Inkscape::Colors::Color;
using Inkscape::UI::Dialog::ColorItem;
using Inkscape::UI::Dialog::GlobalPalettes;
using Inkscape::UI::Dialog::load_palette;
using Inkscape::UI::Dialog::PaletteFileData;
using Inkscape::UI::Widget::ColorPalette;

namespace {

// Number of times the full palette is applied inside one test run. Keep this
// high enough that perf record gets useful samples, low enough for CI budgets.
constexpr int kRebuildIterations = 3;

// Minimum color count we expect from the large palette fixture. MunsellChart
// has thousands of entries; if we fall back to a synthetic palette we still
// generate this many colors so the workload remains representative.
constexpr std::size_t kSyntheticColorCount = 2500;

std::vector<PaletteFileData::ColorItem> make_synthetic_colors(std::size_t count)
{
    std::vector<PaletteFileData::ColorItem> colors;
    colors.reserve(count);
    for (std::size_t i = 0; i < count; ++i) {
        double t = static_cast<double>(i) / static_cast<double>(count);
        colors.emplace_back(Color(0xff000000u | (static_cast<uint32_t>(t * 255) << 16) |
                                  (static_cast<uint32_t>((1.0 - t) * 255) << 8) |
                                  static_cast<uint32_t>((t * 0.5 + 0.25) * 255)));
    }
    return colors;
}

std::vector<PaletteFileData::ColorItem> load_large_palette_colors()
{
    // Prefer the real MunsellChart palette (the pathological case in issue #4396).
    auto const &globals = GlobalPalettes::get();
    for (auto const &pal : globals.palettes()) {
        if (pal.id.find("Munsell") != Glib::ustring::npos ||
            pal.name.find("Munsell") != Glib::ustring::npos) {
            if (!pal.colors.empty()) {
                std::cerr << "color-palette-perf: using global palette '" << pal.name
                          << "' with " << pal.colors.size() << " entries\n";
                return pal.colors;
            }
        }
    }

    // Direct file load as a fallback when GlobalPalettes has not scanned share/.
    std::string const candidates[] = {
        std::string(INKSCAPE_SHARE_DIR) + "/palettes/MunsellChart.gpl",
        "share/palettes/MunsellChart.gpl",
        "../share/palettes/MunsellChart.gpl",
    };
    for (auto const &path : candidates) {
        auto res = load_palette(path);
        if (res.palette && !res.palette->colors.empty()) {
            std::cerr << "color-palette-perf: loaded '" << path << "' with "
                      << res.palette->colors.size() << " entries\n";
            return res.palette->colors;
        }
    }

    std::cerr << "color-palette-perf: MunsellChart unavailable; using synthetic palette of "
              << kSyntheticColorCount << " colors\n";
    return make_synthetic_colors(kSyntheticColorCount);
}

std::vector<std::unique_ptr<ColorItem>> make_color_items(std::vector<PaletteFileData::ColorItem> const &source)
{
    std::vector<std::unique_ptr<ColorItem>> items;
    items.reserve(source.size() + 1);

    // Mirror SwatchesPanel::rebuild(): always include the "paint none" tile.
    items.push_back(std::make_unique<ColorItem>(static_cast<Inkscape::UI::Dialog::DialogBase *>(nullptr)));

    for (auto const &entry : source) {
        if (auto const *color = std::get_if<Color>(&entry)) {
            items.push_back(std::make_unique<ColorItem>(*color, static_cast<Inkscape::UI::Dialog::DialogBase *>(nullptr)));
        } else if (auto const *group = std::get_if<PaletteFileData::GroupStart>(&entry)) {
            items.push_back(std::make_unique<ColorItem>(group->name));
        } else {
            // Spacer / filler alignment item.
            items.push_back(std::make_unique<ColorItem>(""));
        }
    }
    return items;
}

class ColorPalettePerfTest : public ::testing::Test
{
protected:
    static void SetUpTestSuite()
    {
        Glib::init();
        // Prefer a real/Xvfb DISPLAY when present. Only fall back to broadway
        // when neither GDK_BACKEND nor DISPLAY is configured.
        if (!std::getenv("GDK_BACKEND") && !std::getenv("DISPLAY") && !std::getenv("WAYLAND_DISPLAY")) {
            g_setenv("GDK_BACKEND", "broadway", FALSE);
        }
        _app = Gtk::Application::create("org.inkscape.test.color-palette-perf");
        gtk_init();
        _colors = load_large_palette_colors();
        ASSERT_FALSE(_colors.empty());
    }

    static void TearDownTestSuite()
    {
        _colors.clear();
        _app.reset();
    }

    static Glib::RefPtr<Gtk::Application> _app;
    static std::vector<PaletteFileData::ColorItem> _colors;
};

Glib::RefPtr<Gtk::Application> ColorPalettePerfTest::_app;
std::vector<PaletteFileData::ColorItem> ColorPalettePerfTest::_colors;

} // namespace

// Populate a ColorPalette repeatedly with a large color list, matching the
// user-visible "switch to a big palette" workload from issue #4396.
TEST_F(ColorPalettePerfTest, LargePaletteRebuild)
{
    Gtk::Window window;
    window.set_default_size(800, 120);

    ColorPalette palette;
    palette.set_compact(true);
    palette.set_tile_size(16);
    palette.set_tile_border(1);
    palette.set_rows(2);
    palette.enable_stretch(true);
    palette.set_large_pinned_panel(true);
    palette.set_page_size(8);

    window.set_child(palette);
    window.present();

    // Pump once so the widget tree realises before we time the heavy path.
    while (g_main_context_iteration(nullptr, FALSE)) {
    }

    auto const t0 = std::chrono::steady_clock::now();

    for (int iter = 0; iter < kRebuildIterations; ++iter) {
        // Fresh ColorItem instances each iteration (same as SwatchesPanel::rebuild).
        auto items = make_color_items(_colors);
        std::size_t const item_count = items.size();
        palette.set_colors(std::move(items));

        // Process pending size/allocate work like a live UI would.
        while (g_main_context_iteration(nullptr, FALSE)) {
        }

        // Touch layout settings so resize/set_up_scrolling also runs.
        palette.set_rows(2 + (iter % 2));
        palette.set_tile_size(14 + (iter % 4));
        while (g_main_context_iteration(nullptr, FALSE)) {
        }

        EXPECT_GE(item_count, 100u);
    }

    auto const t1 = std::chrono::steady_clock::now();
    auto const ms = std::chrono::duration_cast<std::chrono::milliseconds>(t1 - t0).count();
    std::cerr << "color-palette-perf: " << kRebuildIterations << " rebuild(s) of "
              << _colors.size() << " source colors took " << ms << " ms\n";

    // Soft upper bound: catches catastrophic regressions without flaking on slow VMs.
    // Pre-fix MunsellChart rebuilds often exceed tens of seconds; post-fix should
    // land well under this. Adjust if the host is extremely resource-constrained.
    EXPECT_LT(ms, 120000);
}

// Also exercise the palette selector menu path (previews for many palettes).
TEST_F(ColorPalettePerfTest, PaletteMenuPopulation)
{
    ColorPalette palette;
    std::vector<Inkscape::UI::Widget::palette_t> menu_palettes;

    auto const &globals = GlobalPalettes::get();
    menu_palettes.reserve(globals.palettes().size() + 1);
    menu_palettes.push_back({"Document swatches", "Auto", {}});

    for (auto const &p : globals.palettes()) {
        Inkscape::UI::Widget::palette_t entry;
        entry.name = p.name;
        entry.id = p.id;
        for (auto const &c : p.colors) {
            if (auto const *color = std::get_if<Color>(&c)) {
                if (auto rgb = color->converted(Inkscape::Colors::Space::Type::RGB)) {
                    entry.colors.push_back({(*rgb)[0], (*rgb)[1], (*rgb)[2]});
                }
            }
        }
        menu_palettes.push_back(std::move(entry));
    }

    // If global list is empty, synthesise a few large menu entries.
    if (menu_palettes.size() <= 1) {
        for (int i = 0; i < 20; ++i) {
            Inkscape::UI::Widget::palette_t entry;
            entry.name = "Synthetic " + std::to_string(i);
            entry.id = "synth-" + std::to_string(i);
            for (std::size_t k = 0; k < 64; ++k) {
                entry.colors.push_back({static_cast<double>(k) / 64.0, 0.2, 0.8});
            }
            menu_palettes.push_back(std::move(entry));
        }
    }

    auto const t0 = std::chrono::steady_clock::now();
    for (int iter = 0; iter < kRebuildIterations; ++iter) {
        palette.set_palettes(menu_palettes);
        palette.set_selected(menu_palettes.back().id);
    }
    auto const t1 = std::chrono::steady_clock::now();
    auto const ms = std::chrono::duration_cast<std::chrono::milliseconds>(t1 - t0).count();
    std::cerr << "color-palette-perf: menu population (" << menu_palettes.size()
              << " palettes, " << kRebuildIterations << "x) took " << ms << " ms\n";
    EXPECT_LT(ms, 60000);
}
