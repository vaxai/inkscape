// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Render some items as translucent in a document rendering stack.
 *
 * Author:
 *   Martin Owens <doctormo@geek-2.com>
 *
 * Copyright (C) 2021-2024 Martin Owens
 *
 * Released under GNU GPL v2+, read the file 'COPYING' for more information.
 */

#include "translucency-group.h"

#include "display/drawing-item.h"

#include "document.h"
#include "object/sp-item.h"
#include "object/sp-root.h"
#include "style.h"

namespace Inkscape::Display {

static double TRANSLUCENCY_AMOUNT = 0.2;

TranslucencyGroup::TranslucencyGroup(unsigned int dkey)
    : _dkey(dkey)
{}

/**
 * Set a specific item as the solid item, all other items are made translucent.
 */
void TranslucencyGroup::setSolidItem(SPItem *item)
{
    if (item == _solid_item)
        return;

    // Set the target item, this prevents rerunning rendering.
    _solid_item = item;

    // Reset all the items in the list.
    for (auto &item : _translucent_items) {
        if (auto arenaitem = item->get_arenaitem(_dkey)) {
            arenaitem->setOpacity(item->style->opacity.as_double());
        }
    }
    _translucent_items.clear();

    if (item) {
        _generateTranslucentItems(item->document->getRoot());

        for (auto &item : _translucent_items) {
            Inkscape::DrawingItem *arenaitem = item->get_arenaitem(_dkey);
            arenaitem->setOpacity(TRANSLUCENCY_AMOUNT);
        }
    }
}

/**
 * Generate a new list of sibling items (recursive)
 */
void TranslucencyGroup::_generateTranslucentItems(SPItem *parent)
{
    if (parent == _solid_item)
        return;
    if (parent->isAncestorOf(_solid_item)) {
        for (auto &child: parent->children) {
            if (auto item = cast<SPItem>(&child)) {
                _generateTranslucentItems(item);
            }
        }
    } else {
        _translucent_items.push_back(parent);
    }
}

} /* namespace Inkscape::Display */

/*
  Local Variables:
  mode:c++
  c-file-style:"stroustrup"
  c-file-offsets:((innamespace . 0)(inline-open . 0)(case-label . +))
  indent-tabs-mode:nil
  fill-column:99
  End:
*/
// vim: filetype=cpp:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:fileencoding=utf-8:textwidth=99 :
