import 'package:flutter/material.dart';

import '../models/eraser_mode.dart';
import '../models/grid_style.dart';
import '../models/pencil_lead.dart';
import '../models/pressure_curve.dart';
import '../models/pressure_mode.dart';
import '../models/tool_type.dart';

/// Compact floating vertical palette that docks to screen edges.
///
/// Contains tool selection (with pencil leads + pressure mode), inline color
/// picker, weight slider, grid/paper settings, eraser toggle, and clear canvas.
class FloatingPalette extends StatefulWidget {
  const FloatingPalette({
    super.key,
    required this.currentTool,
    required this.currentColor,
    required this.currentWeight,
    required this.currentLead,
    required this.eraserToggleActive,
    required this.gridStyle,
    required this.gridSpacing,
    required this.paperColor,
    required this.pressureMode,
    required this.pressureCurve,
    required this.eraserMode,
    required this.canUndo,
    required this.canRedo,
    required this.onToolChanged,
    required this.onColorChanged,
    required this.onWeightChanged,
    required this.onLeadChanged,
    required this.onEraserToggle,
    required this.onGridStyleChanged,
    required this.onGridSpacingChanged,
    required this.onPaperColorChanged,
    required this.onPressureModeChanged,
    required this.onPressureCurveChanged,
    required this.onEraserModeChanged,
    required this.onUndo,
    required this.onRedo,
    required this.onClear,
  });

  final ToolType currentTool;
  final int currentColor;
  final double currentWeight;
  final PencilLead? currentLead;
  final bool eraserToggleActive;
  final GridStyle gridStyle;
  final double gridSpacing;
  final Color paperColor;
  final PressureMode pressureMode;
  final PressureCurve pressureCurve;
  final EraserMode eraserMode;
  final bool canUndo;
  final bool canRedo;
  final ValueChanged<ToolType> onToolChanged;
  final ValueChanged<int> onColorChanged;
  final ValueChanged<double> onWeightChanged;
  final ValueChanged<PencilLead> onLeadChanged;
  final VoidCallback onEraserToggle;
  final ValueChanged<GridStyle> onGridStyleChanged;
  final ValueChanged<double> onGridSpacingChanged;
  final ValueChanged<Color> onPaperColorChanged;
  final ValueChanged<PressureMode> onPressureModeChanged;
  final ValueChanged<PressureCurve> onPressureCurveChanged;
  final ValueChanged<EraserMode> onEraserModeChanged;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback onClear;

  @override
  State<FloatingPalette> createState() => _FloatingPaletteState();
}

enum _SubPanel { tool, color, weight, grid }

class _FloatingPaletteState extends State<FloatingPalette> {
  /// Current position of the palette (top-left corner).
  Offset _position = const Offset(16, 80);

  /// Which sub-panel is currently expanded (null = collapsed).
  _SubPanel? _expandedPanel;

  /// Whether the palette is docked to the right edge.
  bool _dockedRight = false;

  /// HSV color state for the inline color picker.
  late HSVColor _hsv;

  /// Whether HSV has been initialized from the widget prop.
  bool _hsvInitialized = false;

  static const double _stripWidth = 48.0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_hsvInitialized) {
      _hsv = HSVColor.fromColor(Color(widget.currentColor));
      _hsvInitialized = true;
    }
  }

  @override
  void didUpdateWidget(covariant FloatingPalette oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Sync HSV when color changes externally (e.g. from undo or load)
    if (oldWidget.currentColor != widget.currentColor &&
        _expandedPanel != _SubPanel.color) {
      _hsv = HSVColor.fromColor(Color(widget.currentColor));
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;

    // Clamp position within screen bounds
    final clampedX = _position.dx.clamp(0.0, screenSize.width - _stripWidth);
    final clampedY = _position.dy.clamp(0.0, screenSize.height - 300);

    // Determine if sub-panels should expand left or right
    final expandsRight = !_dockedRight && clampedX < screenSize.width / 2;

    return Positioned(
      left: clampedX,
      top: clampedY,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Sub-panel on the left (when docked right)
          if (!expandsRight && _expandedPanel != null)
            _buildSubPanel(_expandedPanel!),
          // The vertical strip
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanUpdate: (details) {
              setState(() {
                _position += details.delta;
                _expandedPanel = null; // collapse while dragging
              });
            },
            onPanEnd: (details) {
              // Snap to nearest horizontal edge
              final center = _position.dx + _stripWidth / 2;
              final snapRight = center > screenSize.width / 2;
              setState(() {
                _dockedRight = snapRight;
                _position = Offset(
                  snapRight ? screenSize.width - _stripWidth - 8 : 8,
                  _position.dy.clamp(8.0, screenSize.height - 300),
                );
              });
            },
            child: _buildStrip(),
          ),
          // Sub-panel on the right (when docked left)
          if (expandsRight && _expandedPanel != null)
            _buildSubPanel(_expandedPanel!),
        ],
      ),
    );
  }

  Widget _buildStrip() {
    return Container(
      width: _stripWidth,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Undo / Redo buttons (top of strip)
          _UndoRedoIcon(
            icon: Icons.undo,
            tooltip: 'Undo',
            enabled: widget.canUndo,
            onTap: widget.onUndo,
          ),
          _UndoRedoIcon(
            icon: Icons.redo,
            tooltip: 'Redo',
            enabled: widget.canRedo,
            onTap: widget.onRedo,
          ),
          const _PaletteDivider(),

          // Tool selector
          _PaletteIcon(
            icon: _iconForTool(widget.currentTool),
            tooltip: 'Tool',
            isActive: _expandedPanel == _SubPanel.tool,
            onTap: () => _togglePanel(_SubPanel.tool),
          ),
          const _PaletteDivider(),

          // Color picker (inline sub-panel)
          _ColorSwatch(
            color: Color(widget.currentColor),
            onTap: () => _togglePanel(_SubPanel.color),
          ),
          const _PaletteDivider(),

          // Weight — inline vertical slider (always accessible)
          _InlineWeightSlider(
            value: widget.currentWeight,
            color: Color(widget.currentColor),
            onChanged: widget.onWeightChanged,
          ),
          const _PaletteDivider(),

          // Grid / paper settings
          _PaletteIcon(
            icon: _iconForGridStyle(widget.gridStyle),
            tooltip: 'Grid & Paper',
            isActive: widget.gridStyle != GridStyle.none,
            activeColor: Colors.blueAccent,
            onTap: () {
              _togglePanel(_SubPanel.grid);
            },
          ),
          const _PaletteDivider(),

          // Eraser toggle
          _PaletteIcon(
            icon: Icons.auto_fix_normal,
            tooltip: 'Eraser',
            isActive: widget.eraserToggleActive,
            activeColor: Colors.redAccent,
            onTap: () {
              setState(() => _expandedPanel = null);
              widget.onEraserToggle();
            },
          ),
          const _PaletteDivider(),

          // Clear canvas (with confirmation dialog)
          _PaletteIcon(
            icon: Icons.delete_outline,
            tooltip: 'Clear',
            onTap: () {
              setState(() => _expandedPanel = null);
              _confirmClear(context);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSubPanel(_SubPanel panel) {
    return Padding(
      padding: const EdgeInsets.only(top: 0),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 200),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.75),
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.3),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        padding: const EdgeInsets.all(8),
        child: switch (panel) {
          _SubPanel.tool => _buildToolPanel(),
          _SubPanel.color => _buildColorPanel(),
          _SubPanel.weight => _buildWeightPanel(),
          _SubPanel.grid => _buildGridPanel(),
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Tool panel (with pencil leads + pressure mode)
  // ---------------------------------------------------------------------------

  Widget _buildToolPanel() {
    const tools = <(ToolType, IconData, String)>[
      (ToolType.pencil, Icons.create, 'Pencil'),
      (ToolType.pen, Icons.edit, 'Pen'),
      (ToolType.marker, Icons.brush, 'Marker'),
      (ToolType.highlighter, Icons.highlight, 'Highlighter'),
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Drawing tools
        for (final (tool, icon, label) in tools)
          _ToolRow(
            icon: icon,
            label: label,
            isActive: widget.currentTool == tool && !widget.eraserToggleActive,
            onTap: () {
              widget.onToolChanged(tool);
              // Keep panel open if pencil selected (to show leads)
              if (tool != ToolType.pencil) {
                setState(() => _expandedPanel = null);
              } else {
                setState(() {}); // rebuild to show leads
              }
            },
          ),

        // Pencil leads + pressure mode (shown when pencil is active)
        if (widget.currentTool == ToolType.pencil &&
            !widget.eraserToggleActive) ...[
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Divider(height: 1, color: Colors.white24),
          ),
          const Padding(
            padding: EdgeInsets.only(left: 4, bottom: 4),
            child: Text(
              'Lead',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          for (final lead in PencilLead.values)
            _ToolRow(
              icon: Icons.circle,
              iconSize: 8.0 + lead.weightMultiplier * 4,
              label: lead.label,
              isActive: widget.currentLead == lead,
              onTap: () {
                widget.onLeadChanged(lead);
              },
            ),

          // Pressure mode selector
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Divider(height: 1, color: Colors.white24),
          ),
          const Padding(
            padding: EdgeInsets.only(left: 4, bottom: 4),
            child: Text(
              'Pressure',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final mode in PressureMode.values)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: _ModeChip(
                    label: mode.label,
                    isActive: widget.pressureMode == mode,
                    onTap: () => widget.onPressureModeChanged(mode),
                  ),
                ),
            ],
          ),

          // Pressure curve selector
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Divider(height: 1, color: Colors.white24),
          ),
          const Padding(
            padding: EdgeInsets.only(left: 4, bottom: 4),
            child: Text(
              'Curve',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final curve in PressureCurve.values)
                _ModeChip(
                  label: curve.label,
                  isActive: widget.pressureCurve == curve,
                  onTap: () => widget.onPressureCurveChanged(curve),
                ),
            ],
          ),
        ],

        // Eraser mode selector (shown when eraser is active)
        if (widget.eraserToggleActive) ...[
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Divider(height: 1, color: Colors.white24),
          ),
          const Padding(
            padding: EdgeInsets.only(left: 4, bottom: 4),
            child: Text(
              'Eraser Mode',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final mode in EraserMode.values)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: _ModeChip(
                    label: mode.label,
                    isActive: widget.eraserMode == mode,
                    onTap: () => widget.onEraserModeChanged(mode),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Inline color picker panel
  // ---------------------------------------------------------------------------

  Widget _buildColorPanel() {
    final color = _hsv.toColor();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Color preview swatch
        Container(
          height: 30,
          width: double.infinity,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Colors.white24),
          ),
        ),
        const SizedBox(height: 8),

        // Hue slider (colored track)
        _ColorSliderRow(
          label: 'H',
          value: _hsv.hue,
          min: 0,
          max: 360,
          trackColor: HSVColor.fromAHSV(1, _hsv.hue, 1, 1).toColor(),
          onChanged: (v) {
            setState(() => _hsv = _hsv.withHue(v));
            widget.onColorChanged(_hsv.toColor().toARGB32());
          },
        ),

        // Saturation slider
        _ColorSliderRow(
          label: 'S',
          value: _hsv.saturation,
          min: 0,
          max: 1,
          trackColor: color,
          onChanged: (v) {
            setState(() => _hsv = _hsv.withSaturation(v));
            widget.onColorChanged(_hsv.toColor().toARGB32());
          },
        ),

        // Brightness slider
        _ColorSliderRow(
          label: 'B',
          value: _hsv.value,
          min: 0,
          max: 1,
          trackColor: color,
          onChanged: (v) {
            setState(() => _hsv = _hsv.withValue(v));
            widget.onColorChanged(_hsv.toColor().toARGB32());
          },
        ),

        const SizedBox(height: 6),

        // Quick presets (2 rows of 4)
        _buildQuickColorPresets(),
      ],
    );
  }

  Widget _buildQuickColorPresets() {
    const presets = <(Color, String)>[
      (Colors.black, 'Black'),
      (Colors.white, 'White'),
      (Color(0xFFE53935), 'Red'),
      (Color(0xFF1E88E5), 'Blue'),
      (Color(0xFF43A047), 'Green'),
      (Color(0xFFFDD835), 'Yellow'),
      (Color(0xFFFB8C00), 'Orange'),
      (Color(0xFF8E24AA), 'Purple'),
    ];

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            for (final preset in presets.take(4))
              _QuickColorDot(
                color: preset.$1,
                tooltip: preset.$2,
                onTap: () {
                  setState(() => _hsv = HSVColor.fromColor(preset.$1));
                  widget.onColorChanged(preset.$1.toARGB32());
                },
              ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            for (final preset in presets.skip(4))
              _QuickColorDot(
                color: preset.$1,
                tooltip: preset.$2,
                onTap: () {
                  setState(() => _hsv = HSVColor.fromColor(preset.$1));
                  widget.onColorChanged(preset.$1.toARGB32());
                },
              ),
          ],
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Weight panel
  // ---------------------------------------------------------------------------

  Widget _buildWeightPanel() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.currentWeight.toStringAsFixed(1),
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
        SizedBox(
          width: 180,
          child: Slider(
            value: widget.currentWeight,
            min: 0.5,
            max: 50.0,
            divisions: 99,
            onChanged: widget.onWeightChanged,
          ),
        ),
        // Visual preview of stroke weight
        Container(
          width: 180,
          height: 20,
          alignment: Alignment.center,
          child: Container(
            width: 60,
            height: widget.currentWeight.clamp(1.0, 20.0),
            decoration: BoxDecoration(
              color: Color(widget.currentColor),
              borderRadius: BorderRadius.circular(widget.currentWeight / 2),
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Grid & paper panel
  // ---------------------------------------------------------------------------

  Widget _buildGridPanel() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Grid style selector
        const Padding(
          padding: EdgeInsets.only(left: 4, bottom: 4),
          child: Text(
            'Grid Style',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final style in GridStyle.values)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: _GridStyleChip(
                  icon: _iconForGridStyle(style),
                  label: style.label,
                  isActive: widget.gridStyle == style,
                  onTap: () => widget.onGridStyleChanged(style),
                ),
              ),
          ],
        ),

        // Spacing slider (only when grid is visible)
        if (widget.gridStyle != GridStyle.none) ...[
          const SizedBox(height: 8),
          SizedBox(
            width: 180,
            child: Slider(
              value: widget.gridSpacing,
              min: 10.0,
              max: 80.0,
              divisions: 14,
              label: '${widget.gridSpacing.round()}px',
              onChanged: widget.onGridSpacingChanged,
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              '${widget.gridSpacing.round()}px spacing',
              style: const TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ),
        ],

        // Paper color presets
        const SizedBox(height: 8),
        const Divider(height: 1, color: Colors.white24),
        const SizedBox(height: 8),
        const Padding(
          padding: EdgeInsets.only(left: 4, bottom: 6),
          child: Text(
            'Paper Color',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (color, label) in _paperColorPresets)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: _PaperColorChip(
                  color: color,
                  label: label,
                  isActive: _colorsMatch(widget.paperColor, color),
                  onTap: () => widget.onPaperColorChanged(color),
                ),
              ),
          ],
        ),
      ],
    );
  }

  /// Paper color presets — curated set of common paper colors.
  static const _paperColorPresets = <(Color, String)>[
    (Color(0xFFFFFFFF), 'White'),
    (Color(0xFFF5F5F0), 'Cream'),
    (Color(0xFFE8E0D0), 'Tan'),
    (Color(0xFFD0D0D0), 'Gray'),
    (Color(0xFF2D2D2D), 'Dark'),
    (Color(0xFF1A1A2E), 'Navy'),
  ];

  /// Compare two colors ignoring minor floating-point differences.
  bool _colorsMatch(Color a, Color b) {
    return a.toARGB32() == b.toARGB32();
  }

  IconData _iconForGridStyle(GridStyle style) {
    return switch (style) {
      GridStyle.none => Icons.crop_free,
      GridStyle.dots => Icons.grid_4x4,
      GridStyle.lines => Icons.grid_on,
    };
  }

  /// Show a confirmation dialog before clearing the canvas.
  void _confirmClear(BuildContext context) {
    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: const Text(
          'Clear Canvas?',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'This will remove all strokes on the current page. You can undo this action.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('Clear'),
          ),
        ],
      ),
    ).then((confirmed) {
      if (confirmed == true) {
        widget.onClear();
      }
    });
  }

  void _togglePanel(_SubPanel panel) {
    setState(() {
      _expandedPanel = _expandedPanel == panel ? null : panel;
    });
  }

  IconData _iconForTool(ToolType tool) {
    return switch (tool) {
      ToolType.pen => Icons.edit,
      ToolType.pencil => Icons.create,
      ToolType.marker => Icons.brush,
      ToolType.brush => Icons.brush,
      ToolType.highlighter => Icons.highlight,
      ToolType.eraser => Icons.auto_fix_normal,
    };
  }
}

// =============================================================================
// Palette sub-widgets
// =============================================================================

/// An undo/redo icon button — dims when disabled.
class _UndoRedoIcon extends StatelessWidget {
  const _UndoRedoIcon({
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 40,
          height: 32,
          alignment: Alignment.center,
          child: Icon(
            icon,
            color: enabled ? Colors.white70 : Colors.white24,
            size: 20,
          ),
        ),
      ),
    );
  }
}

/// A single icon button in the palette strip.
class _PaletteIcon extends StatelessWidget {
  const _PaletteIcon({
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.isActive = false,
    this.activeColor = Colors.white,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  final bool isActive;
  final Color activeColor;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip ?? '',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: isActive
              ? BoxDecoration(
                  color: activeColor.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                )
              : null,
          child: Icon(
            icon,
            color: isActive ? activeColor : Colors.white70,
            size: 22,
          ),
        ),
      ),
    );
  }
}

/// The color swatch button in the palette strip.
class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({required this.color, required this.onTap});

  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Color',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          child: Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white54, width: 2),
            ),
          ),
        ),
      ),
    );
  }
}

/// A thin divider between palette items.
class _PaletteDivider extends StatelessWidget {
  const _PaletteDivider();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Divider(height: 1, color: Colors.white.withValues(alpha: 0.15)),
    );
  }
}

/// A row in the tool sub-panel (tool name + icon).
class _ToolRow extends StatelessWidget {
  const _ToolRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.isActive = false,
    this.iconSize = 18,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isActive;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: isActive
            ? BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
              )
            : null,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: iconSize, color: Colors.white70),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: isActive ? Colors.white : Colors.white70,
                fontSize: 13,
              ),
            ),
            if (isActive) ...[
              const SizedBox(width: 8),
              const Icon(Icons.check, size: 14, color: Colors.white),
            ],
          ],
        ),
      ),
    );
  }
}

/// A compact chip for selecting grid style (None / Dots / Lines).
class _GridStyleChip extends StatelessWidget {
  const _GridStyleChip({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: isActive
              ? Colors.blueAccent.withValues(alpha: 0.3)
              : Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(6),
          border: isActive
              ? Border.all(color: Colors.blueAccent, width: 1)
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18,
                color: isActive ? Colors.blueAccent : Colors.white70),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                color: isActive ? Colors.blueAccent : Colors.white54,
                fontSize: 9,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A paper color preset chip — circular swatch with selection ring.
class _PaperColorChip extends StatelessWidget {
  const _PaperColorChip({
    required this.color,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  final Color color;
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: isActive ? Colors.blueAccent : Colors.white38,
              width: isActive ? 2.5 : 1,
            ),
          ),
        ),
      ),
    );
  }
}

/// A compact mode selector chip (for pressure mode).
class _ModeChip extends StatelessWidget {
  const _ModeChip({
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  final String label;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: isActive
              ? Colors.blueAccent.withValues(alpha: 0.3)
              : Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(6),
          border: isActive
              ? Border.all(color: Colors.blueAccent, width: 1)
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isActive ? Colors.blueAccent : Colors.white54,
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// A compact slider row for the inline color picker.
class _ColorSliderRow extends StatelessWidget {
  const _ColorSliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.trackColor,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final Color trackColor;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 16,
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 8,
              activeTrackColor: trackColor,
              inactiveTrackColor: Colors.white12,
              thumbColor: Colors.white,
              overlayColor: Colors.white24,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            ),
            child: Slider(
              value: value,
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }
}

/// A quick color preset dot for the inline color picker.
class _QuickColorDot extends StatelessWidget {
  const _QuickColorDot({
    required this.color,
    required this.tooltip,
    required this.onTap,
  });

  final Color color;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white38, width: 1),
          ),
        ),
      ),
    );
  }
}

/// Compact vertical weight slider that fits inline in the palette strip.
///
/// Shows a rotated slider with a dot preview of the current weight.
/// Height is compact (120px) to fit in the vertical palette.
class _InlineWeightSlider extends StatelessWidget {
  const _InlineWeightSlider({
    required this.value,
    required this.color,
    required this.onChanged,
  });

  final double value;
  final Color color;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 48,
      height: 120,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Weight preview dot (scales with current weight)
          Container(
            width: value.clamp(4.0, 20.0),
            height: value.clamp(4.0, 20.0),
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white38,
                width: 0.5,
              ),
            ),
          ),
          const SizedBox(height: 2),
          // Vertical slider (rotated)
          Expanded(
            child: RotatedBox(
              quarterTurns: 3,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3.0,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 6),
                  activeTrackColor: Colors.white70,
                  inactiveTrackColor: Colors.white24,
                  thumbColor: Colors.white,
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 12),
                ),
                child: Slider(
                  value: value,
                  min: 0.5,
                  max: 50.0,
                  onChanged: onChanged,
                ),
              ),
            ),
          ),
          // Weight value label
          Text(
            value.toStringAsFixed(1),
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 9,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}
