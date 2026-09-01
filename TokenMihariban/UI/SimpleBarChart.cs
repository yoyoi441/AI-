using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using Color = System.Windows.Media.Color;

namespace TokenMihariban.UI;

/// <summary>
/// A plain (non-interactive) bar chart for the tray popup — the Windows equivalent of
/// the Mac/iOS/Android hourly usage chart, minus the press-and-hold tooltip (mouse
/// hover is the natural desktop analogue, but a tray popup is dismissed the moment
/// focus leaves it, which makes a hover tooltip awkward to use reliably; a plain chart
/// with proportional bars is a reasonable v1 simplification here).
/// </summary>
internal static class SimpleBarChart
{
    public static FrameworkElement Build(IReadOnlyList<double> values, Color color, double height = 60)
    {
        if (values.Count == 0) return new StackPanel();
        var max = values.Max();
        if (max <= 0) max = 1;

        var panel = new UniformGrid { Rows = 1, Height = height };
        var brush = new SolidColorBrush(color);
        foreach (var value in values)
        {
            var fraction = Math.Clamp(value / max, 0.02, 1.0);
            var bar = new Border
            {
                Background = brush,
                Opacity = 0.85,
                Margin = new Thickness(1, 0, 1, 0),
                VerticalAlignment = VerticalAlignment.Bottom,
                Height = height * fraction,
                CornerRadius = new CornerRadius(2, 2, 0, 0)
            };
            var cell = new Grid { VerticalAlignment = VerticalAlignment.Bottom };
            cell.Children.Add(bar);
            panel.Children.Add(cell);
        }
        return panel;
    }
}
