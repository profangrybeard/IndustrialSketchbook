import 'package:flutter/material.dart';

import '../models/pencil_lead.dart';
import '../models/tool_type.dart';
import 'color_wheel_dialog.dart';

/// Compact floating vertical palette that docks to screen edges.
///
/// Contains tool selection (with pencil leads), color picker, weight slider,
/// grid toggle, eraser toggle, and clear canvas actions.
class FloatingPalette extends StatefulWidget {
  const FloatingPalette({
    super.key,
    required this.currentTool,
    required this.currentColor,
    required this.currentWeight,
    required this.currentLead,
    required this.eraserToggleActive,
    required this.gridEnabled,
    required this.gridSpacing,
    required this.onToolChanged,
    required this.onColorChanged,
    required this.onWeightChanged,
    required this.onLeadChanged,
    required this.onEraserToggle,
    required this.onGridToggle,
    required this.onGridSpacingChanged,
    required this.onClear,
  });

  final ToolType currentTool;
  final int currentColor;
  final double currentWeight;
  final PencilLead? currentLead;
  final bool eraserToggleActive;
  final bool gridEnabled;
  final double gridSpacing;
  final ValueChanged<ToolType> onToolChanged;
  final ValueChanged<int> onColorChanged;
  final ValueChanged<double> onWeightChanged;
  final ValueChanged<PencilLead> onLeadChanged;
  final VoidCallback onEraserToggle;
  final VoidCallback onGridToggle;
  final ValueChanged<double> onGridSpacingChanged;
  final VoidCallback onClear;

  @override
  State<FloatingPalette> createState() => _FloatingPaletteState();
}

enum _SubPanel { tool, weight, grid }

class _FloatingPaletteState extends State<FloatingPalette> {
  /// Current position of the palette (top-left corner).
  Offset _position = const Offset(16, 80);

  /// Which sub-panel is currently expanded (null = collapsed).
  _SubPanel? _expandedPanel;

  /// Whether the palette is docked to the right edge.
  bool _dockedRight = false;

  static const double _stripWidth = 48.0;

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
          // Tool selector
          _PaletteIcon(
            icon: _iconForTool(widget.currentTool),
            tooltip: 'Tool',
            isActive: _expandedPanel == _SubPanel.tool,
            onTap: () => _togglePanel(_SubPanel.tool),
          ),
          const _PaletteDivider(),

          // Color picker
          _ColorSwatch(
            color: Color(widget.currentColor),
            onTap: () {
              setState(() => _expandedPanel = null);
              _showColorPicker();
            },
          ),
          const _PaletteDivider(),

          // Weight
          _PaletteIcon(
            icon: Icons.line_weight,
            tooltip: 'Stroke weight',
            isActive: _expandedPanel == _SubPanel.weight,
            onTap: () => _togglePanel(_SubPanel.weight),
          ),
          const _PaletteDivider(),

          // Grid toggle
          _PaletteIcon(
            icon: Icons.grid_4x4,
            tooltip: 'Grid',
            isActive: widget.gridEnabled,
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

          // Clear canvas
          _PaletteIcon(
            icon: Icons.delete_outline,
            tooltip: 'Clear',
            onTap: () {
              setState(() => _expandedPanel = null);
              widget.onClear();
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
          _SubPanel.weight => _buildWeightPanel(),
          _SubPanel.grid => _buildGridPanel(),
        },
      ),
    );
  }

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

        // Pencil leads (shown when pencil is active)
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
        ],
      ],
    );
  }

  Widget _buildWeightPanel() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.currentWeight.toStringAsFixed(1),
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
        RotatedBox(
          quarterTurns: 0,
          child: SizedBox(
            width: 180,
            child: Slider(
              value: widget.currentWeight,
              min: 0.5,
              max: 50.0,
              divisions: 99,
              onChanged: widget.onWeightChanged,
            ),
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

  Widget _buildGridPanel() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Grid',
              style: TextStyle(color: Colors.white, fontSize: 13),
            ),
            const SizedBox(width: 8),
            Switch(
              value: widget.gridEnabled,
              onChanged: (_) => widget.onGridToggle(),
              activeColor: Colors.blueAccent,
            ),
          ],
        ),
        if (widget.gridEnabled) ...[
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
          Text(
            '${widget.gridSpacing.round()}px spacing',
            style: const TextStyle(color: Colors.white54, fontSize: 11),
          ),
        ],
      ],
    );
  }

  void _togglePanel(_SubPanel panel) {
    setState(() {
      _expandedPanel = _expandedPanel == panel ? null : panel;
    });
  }

  void _showColorPicker() {
    showDialog(
      context: context,
      builder: (ctx) => ColorWheelDialog(
        initialColor: Color(widget.currentColor),
        onColorPicked: (color) {
          widget.onColorChanged(color.toARGB32());
        },
      ),
    );
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
