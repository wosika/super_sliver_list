import "package:flutter/foundation.dart";
import "package:flutter/widgets.dart";

import "super_sliver_list.dart";

/// Signature for the builder callback used by [SuperAnimateSliverList] to build
/// its animated children.
///
/// The [context] argument is the build context where the widget will be
/// created, the [index] is the index of the item to be built, and the
/// [animation] is an [Animation] that should be used to animate an entry
/// transition for the widget that is built.
typedef AnimatedItemBuilder = Widget Function(
  BuildContext context,
  int index,
  Animation<double> animation,
);

/// Signature for the builder callback used in
/// [SuperAnimateSliverListState.removeItem] to animate children after they have
/// been removed.
///
/// The [context] argument is the build context where the widget will be
/// created, and the [animation] is an [Animation] that should be used to
/// animate an exit transition for the widget that is built.
typedef AnimatedRemovedItemBuilder = Widget Function(
  BuildContext context,
  Animation<double> animation,
);

// The default insert/remove animation duration.
const Duration _kDuration = Duration(milliseconds: 300);

// Incoming and outgoing animated items.
class _ActiveItem implements Comparable<_ActiveItem> {
  _ActiveItem.incoming(this.controller, this.itemIndex)
      : removedItemBuilder = null;
  _ActiveItem.outgoing(
      this.controller, this.itemIndex, this.removedItemBuilder);
  _ActiveItem.index(this.itemIndex)
      : controller = null,
        removedItemBuilder = null;

  final AnimationController? controller;
  final AnimatedRemovedItemBuilder? removedItemBuilder;
  int itemIndex;

  @override
  int compareTo(_ActiveItem other) => itemIndex - other.itemIndex;
}

/// A [SuperSliverList] that animates items when they are inserted or removed.
///
/// This widget combines the performance advantages of [SuperSliverList] (extent
/// management, Fenwick tree, jump/animate to item) with insert/remove animation
/// capabilities similar to [SliverAnimatedList].
///
/// This widget's [SuperAnimateSliverListState] can be used to dynamically
/// insert or remove items. To refer to the [SuperAnimateSliverListState] either
/// provide a [GlobalKey] or use the static [of] method from an item's input
/// callback.
///
/// Example usage:
/// ```dart
/// final _listKey = GlobalKey<SuperAnimateSliverListState>();
///
/// SuperAnimateSliverList(
///   key: _listKey,
///   initialItemCount: _items.length,
///   itemBuilder: (context, index, animation) {
///     return SizeTransition(
///       sizeFactor: animation,
///       child: ListTile(title: Text(_items[index])),
///     );
///   },
/// )
///
/// // To insert:
/// _listKey.currentState!.insertItem(0);
///
/// // To remove:
/// _listKey.currentState!.removeItem(0, (context, animation) {
///   return SizeTransition(
///     sizeFactor: animation,
///     child: ListTile(title: Text(removedItem)),
///   );
/// });
/// ```
class SuperAnimateSliverList extends StatefulWidget {
  const SuperAnimateSliverList({
    super.key,
    required this.itemBuilder,
    this.initialItemCount = 0,
    this.listController,
    this.extentEstimation,
    this.extentPrecalculationPolicy,
    this.delayPopulatingCacheArea = true,
    this.layoutKeptAliveChildren = false,
  }) : assert(initialItemCount >= 0);

  /// Called, as needed, to build children widgets.
  ///
  /// Children are only built when they're scrolled into view.
  ///
  /// The [index] parameter indicates the item's position in the list. The value
  /// of the index parameter will be between 0 and [initialItemCount] plus the
  /// total number of items that have been inserted with
  /// [SuperAnimateSliverListState.insertItem] and less the total number of
  /// items that have been removed with
  /// [SuperAnimateSliverListState.removeItem].
  ///
  /// Implementations of this callback should assume that
  /// `removeItem` removes an item immediately.
  final AnimatedItemBuilder itemBuilder;

  /// The number of items the list will start with.
  ///
  /// The appearance of the initial items is not animated. They are created, as
  /// needed, by [itemBuilder] with an animation parameter of
  /// [kAlwaysCompleteAnimation].
  final int initialItemCount;

  /// When set provides access to extents of individual children.
  /// [ListController] can also be used to jump to a specific item in the list.
  final ListController? listController;

  /// Optional method that can be used to override default estimated extent for
  /// each item.
  final ExtentEstimationProvider? extentEstimation;

  /// Optional policy that can be used to asynchronously precalculate the
  /// extents of the items in the list.
  final ExtentPrecalculationPolicy? extentPrecalculationPolicy;

  /// Whether the items in cache area should be built delayed.
  final bool delayPopulatingCacheArea;

  /// Whether children with keepAlive should be laid out.
  final bool layoutKeptAliveChildren;

  @override
  SuperAnimateSliverListState createState() => SuperAnimateSliverListState();

  /// The [SuperAnimateSliverListState] from the closest instance of this class
  /// that encloses the given context.
  ///
  /// This method is typically used by [SuperAnimateSliverList] item widgets
  /// that insert or remove items in response to user input.
  ///
  /// If no [SuperAnimateSliverList] surrounds the context given, then this
  /// function will assert in debug mode and throw an exception in release mode.
  ///
  /// This method can be expensive (it walks the element tree).
  static SuperAnimateSliverListState of(BuildContext context) {
    final SuperAnimateSliverListState? result =
        SuperAnimateSliverList.maybeOf(context);
    assert(() {
      if (result == null) {
        throw FlutterError(
          "SuperAnimateSliverList.of() called with a context that does not "
          "contain a SuperAnimateSliverList.\n"
          "No SuperAnimateSliverListState ancestor could be found starting "
          "from the context that was passed to "
          "SuperAnimateSliverListState.of().\n"
          "The context used was:\n"
          "  $context",
        );
      }
      return true;
    }());
    return result!;
  }

  /// The [SuperAnimateSliverListState] from the closest instance of this class
  /// that encloses the given context.
  ///
  /// This method is typically used by [SuperAnimateSliverList] item widgets
  /// that insert or remove items in response to user input.
  ///
  /// If no [SuperAnimateSliverList] surrounds the context given, then this
  /// function will return null.
  ///
  /// This method can be expensive (it walks the element tree).
  static SuperAnimateSliverListState? maybeOf(BuildContext context) {
    return context.findAncestorStateOfType<SuperAnimateSliverListState>();
  }
}

/// The state for a [SuperAnimateSliverList] that animates items when they are
/// inserted or removed.
///
/// When an item is inserted with [insertItem] an animation begins running. The
/// animation is passed to [SuperAnimateSliverList.itemBuilder] whenever the
/// item's widget is needed.
///
/// When an item is removed with [removeItem] its animation is reversed. The
/// removed item's animation is passed to the [removeItem] builder parameter.
class SuperAnimateSliverListState extends State<SuperAnimateSliverList>
    with TickerProviderStateMixin {
  final List<_ActiveItem> _incomingItems = <_ActiveItem>[];
  final List<_ActiveItem> _outgoingItems = <_ActiveItem>[];
  int _itemsCount = 0;
  ListController? _internalListController;

  ListController get _effectiveListController =>
      widget.listController ?? (_internalListController ??= ListController());

  @override
  void initState() {
    super.initState();
    _itemsCount = widget.initialItemCount;
  }

  @override
  void dispose() {
    for (final _ActiveItem item
        in _incomingItems.followedBy(_outgoingItems)) {
      item.controller!.dispose();
    }
    _internalListController?.dispose();
    super.dispose();
  }

  _ActiveItem? _removeActiveItemAt(List<_ActiveItem> items, int itemIndex) {
    final int i = binarySearch(items, _ActiveItem.index(itemIndex));
    return i == -1 ? null : items.removeAt(i);
  }

  _ActiveItem? _activeItemAt(List<_ActiveItem> items, int itemIndex) {
    final int i = binarySearch(items, _ActiveItem.index(itemIndex));
    return i == -1 ? null : items[i];
  }

  // The insertItem() and removeItem() index parameters are defined as if the
  // removeItem() operation removed the corresponding list entry immediately.
  // The entry is only actually removed from the list when the remove animation
  // finishes. The entry is added to _outgoingItems when removeItem is called
  // and removed from _outgoingItems when the remove animation finishes.

  int _indexToItemIndex(int index) {
    int itemIndex = index;
    for (final _ActiveItem item in _outgoingItems) {
      if (item.itemIndex <= itemIndex) {
        itemIndex += 1;
      } else {
        break;
      }
    }
    return itemIndex;
  }

  int _itemIndexToIndex(int itemIndex) {
    int index = itemIndex;
    for (final _ActiveItem item in _outgoingItems) {
      assert(item.itemIndex != itemIndex);
      if (item.itemIndex < itemIndex) {
        index -= 1;
      } else {
        break;
      }
    }
    return index;
  }

  Widget _itemBuilder(BuildContext context, int itemIndex) {
    final _ActiveItem? outgoingItem =
        _activeItemAt(_outgoingItems, itemIndex);
    if (outgoingItem != null) {
      return outgoingItem.removedItemBuilder!(
          context, outgoingItem.controller!.view);
    }

    final _ActiveItem? incomingItem =
        _activeItemAt(_incomingItems, itemIndex);
    final Animation<double> animation =
        incomingItem?.controller?.view ?? kAlwaysCompleteAnimation;
    return widget.itemBuilder(
        context, _itemIndexToIndex(itemIndex), animation);
  }

  /// Insert an item at [index] and start an animation that will be passed to
  /// [SuperAnimateSliverList.itemBuilder] when the item is visible.
  ///
  /// This method's semantics are the same as Dart's [List.insert] method: it
  /// increases the length of the list of items by one and shifts all items at
  /// or after [index] towards the end of the list of items.
  void insertItem(int index, {Duration duration = _kDuration}) {
    assert(index >= 0);

    final int itemIndex = _indexToItemIndex(index);
    assert(itemIndex >= 0 && itemIndex <= _itemsCount);

    // Increment the incoming and outgoing item indices to account
    // for the insertion.
    for (final _ActiveItem item in _incomingItems) {
      if (item.itemIndex >= itemIndex) {
        item.itemIndex += 1;
      }
    }
    for (final _ActiveItem item in _outgoingItems) {
      if (item.itemIndex >= itemIndex) {
        item.itemIndex += 1;
      }
    }

    final AnimationController controller =
        AnimationController(duration: duration, vsync: this);
    final _ActiveItem incomingItem =
        _ActiveItem.incoming(controller, itemIndex);
    setState(() {
      _incomingItems
        ..add(incomingItem)
        ..sort();
      _itemsCount += 1;
    });

    // Notify the extent manager about the new item.
    final listController = _effectiveListController;
    if (listController.isAttached && !listController.isLocked) {
      listController.addItem(index);
    }

    controller.forward().then<void>((_) {
      _removeActiveItemAt(_incomingItems, incomingItem.itemIndex)!
          .controller!
          .dispose();
    });
  }

  /// Insert multiple items at [index] and start an animation that will be
  /// passed to [SuperAnimateSliverList.itemBuilder] when the items are visible.
  void insertAllItems(int index, int length,
      {Duration duration = _kDuration}) {
    for (int i = 0; i < length; i++) {
      insertItem(index + i, duration: duration);
    }
  }

  /// Remove the item at [index] and start an animation that will be passed to
  /// [builder] when the item is visible.
  ///
  /// Items are removed immediately. After an item has been removed, its index
  /// will no longer be passed to [SuperAnimateSliverList.itemBuilder]. However
  /// the item will still appear for [duration], and during that time [builder]
  /// must construct its widget as needed.
  ///
  /// This method's semantics are the same as Dart's [List.remove] method: it
  /// decreases the length of items by one and shifts all items at or before
  /// [index] towards the beginning of the list of items.
  void removeItem(
    int index,
    AnimatedRemovedItemBuilder builder, {
    Duration duration = _kDuration,
  }) {
    assert(index >= 0);

    final int itemIndex = _indexToItemIndex(index);
    assert(itemIndex >= 0 && itemIndex < _itemsCount);
    assert(_activeItemAt(_outgoingItems, itemIndex) == null);

    final _ActiveItem? incomingItem =
        _removeActiveItemAt(_incomingItems, itemIndex);
    final AnimationController controller = incomingItem?.controller ??
        AnimationController(duration: duration, value: 1.0, vsync: this);
    final _ActiveItem outgoingItem =
        _ActiveItem.outgoing(controller, itemIndex, builder);
    setState(() {
      _outgoingItems
        ..add(outgoingItem)
        ..sort();
    });

    controller.reverse().then<void>((void value) {
      _removeActiveItemAt(_outgoingItems, outgoingItem.itemIndex)!
          .controller!
          .dispose();

      // Decrement the incoming and outgoing item indices to account
      // for the removal.
      for (final _ActiveItem item in _incomingItems) {
        if (item.itemIndex > outgoingItem.itemIndex) {
          item.itemIndex -= 1;
        }
      }
      for (final _ActiveItem item in _outgoingItems) {
        if (item.itemIndex > outgoingItem.itemIndex) {
          item.itemIndex -= 1;
        }
      }

      setState(() => _itemsCount -= 1);

      // Notify the extent manager about the removed item after the animation
      // completes and the item count has been decremented.
      final listController = _effectiveListController;
      if (listController.isAttached && !listController.isLocked) {
        listController.removeItem(index);
      }
    });
  }

  /// Remove all the items and start an animation that will be passed to
  /// [builder] when the items are visible.
  ///
  /// Items are removed immediately. However, the items will still appear for
  /// [duration], and during that time [builder] must construct its widget as
  /// needed.
  void removeAllItems(
    AnimatedRemovedItemBuilder builder, {
    Duration duration = _kDuration,
  }) {
    for (int i = _itemsCount - 1; i >= 0; i--) {
      removeItem(i, builder, duration: duration);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SuperSliverList(
      listController: _effectiveListController,
      extentEstimation: widget.extentEstimation,
      extentPrecalculationPolicy: widget.extentPrecalculationPolicy,
      delayPopulatingCacheArea: widget.delayPopulatingCacheArea,
      layoutKeptAliveChildren: widget.layoutKeptAliveChildren,
      delegate: SliverChildBuilderDelegate(
        _itemBuilder,
        childCount: _itemsCount,
      ),
    );
  }
}
