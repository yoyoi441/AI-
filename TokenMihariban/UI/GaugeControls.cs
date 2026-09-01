using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using Brush = System.Windows.Media.Brush;
using Color = System.Windows.Media.Color;
using HorizontalAlignment = System.Windows.HorizontalAlignment;
using Point = System.Windows.Point;
using Size = System.Windows.Size;

namespace TokenMihariban.UI;

/// <summary>Small WPF helpers building the ring/bar gauge visuals used throughout the popup — the Windows equivalent of the shared CircularGaugeRing/GaugeBar views on the other platforms.</summary>
internal static class GaugeControls
{
    public static Color ParseColor(string hex, Color fallback)
    {
        var sanitized = hex.TrimStart('#');
        if (sanitized.Length != 6 || !int.TryParse(sanitized, System.Globalization.NumberStyles.HexNumber, null, out var rgb)) return fallback;
        return Color.FromRgb((byte)((rgb >> 16) & 0xFF), (byte)((rgb >> 8) & 0xFF), (byte)(rgb & 0xFF));
    }

    private static Point PointOnCircle(Point center, double radius, double angleDegrees)
    {
        var rad = angleDegrees * Math.PI / 180.0;
        return new Point(center.X + radius * Math.Cos(rad), center.Y + radius * Math.Sin(rad));
    }

    private static Path RingArc(double fraction, Brush stroke, double diameter, double thickness)
    {
        fraction = Math.Clamp(fraction, 0.001, 0.999);
        var radius = (diameter - thickness) / 2;
        var center = new Point(diameter / 2, diameter / 2);
        var angle = fraction * 360.0;
        var startPoint = PointOnCircle(center, radius, -90);
        var endPoint = PointOnCircle(center, radius, -90 + angle);
        var isLargeArc = angle > 180;

        var figure = new PathFigure { StartPoint = startPoint, IsClosed = false };
        figure.Segments.Add(new ArcSegment(endPoint, new Size(radius, radius), 0, isLargeArc, SweepDirection.Clockwise, true));
        var geometry = new PathGeometry();
        geometry.Figures.Add(figure);
        return new Path
        {
            Data = geometry,
            Stroke = stroke,
            StrokeThickness = thickness,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round
        };
    }

    private static Brush GaugeBrush(Color color, bool useGradient)
    {
        if (!useGradient) return new SolidColorBrush(color);
        var light = Color.FromArgb(160, color.R, color.G, color.B);
        return new LinearGradientBrush(light, color, new Point(0, 0), new Point(1, 1));
    }

    /// <summary>A ring gauge with center text and a caption below it, matching the Mac/iOS/Android "CircularGaugeRing" composite.</summary>
    public static FrameworkElement Ring(double fraction, Color color, bool useGradient, string centerText, string caption, double diameter = 84)
    {
        var track = RingArc(1.0, new SolidColorBrush(Color.FromArgb(45, 128, 128, 128)), diameter, 8);
        var fill = RingArc(fraction, GaugeBrush(color, useGradient), diameter, 8);

        var canvas = new Canvas { Width = diameter, Height = diameter };
        canvas.Children.Add(track);
        canvas.Children.Add(fill);

        var centerLabel = new TextBlock
        {
            Text = centerText,
            FontWeight = FontWeights.Bold,
            FontSize = 15,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center
        };
        var grid = new Grid { Width = diameter, Height = diameter };
        grid.Children.Add(canvas);
        grid.Children.Add(centerLabel);

        var stack = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(4) };
        stack.Children.Add(grid);
        stack.Children.Add(new TextBlock
        {
            Text = caption,
            FontSize = 11,
            Opacity = 0.65,
            HorizontalAlignment = HorizontalAlignment.Center,
            TextAlignment = TextAlignment.Center,
            Margin = new Thickness(0, 4, 0, 0),
            TextWrapping = TextWrapping.Wrap,
            MaxWidth = diameter + 20
        });
        return stack;
    }

    /// <summary>A horizontal bar gauge with a caption/value row above it, matching the Mac/iOS/Android "GaugeBar" composite.</summary>
    public static FrameworkElement Bar(double fraction, Color color, bool useGradient, string caption, string valueText)
    {
        fraction = Math.Clamp(fraction, 0, 1);
        var stack = new StackPanel { Margin = new Thickness(0, 4, 0, 4) };

        var header = new Grid();
        header.ColumnDefinitions.Add(new ColumnDefinition());
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var captionLabel = new TextBlock { Text = caption, FontSize = 11, Opacity = 0.65 };
        var valueLabel = new TextBlock { Text = valueText, FontSize = 11 };
        Grid.SetColumn(valueLabel, 1);
        header.Children.Add(captionLabel);
        header.Children.Add(valueLabel);
        stack.Children.Add(header);

        var barHeight = 10.0;
        var track = new Border
        {
            Height = barHeight,
            CornerRadius = new CornerRadius(barHeight / 2),
            Background = new SolidColorBrush(Color.FromArgb(45, 128, 128, 128)),
            Margin = new Thickness(0, 4, 0, 0)
        };
        var grid = new Grid();
        grid.Children.Add(track);
        // A zero-width filled bar is invisible anyway, so the fill is sized via a
        // proportional grid column rather than an explicit pixel width — no converter
        // or data binding needed to keep it in sync with the container's actual size.
        var proportionalGrid = new Grid();
        proportionalGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(0.02, fraction), GridUnitType.Star) });
        proportionalGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(0.001, 1 - fraction), GridUnitType.Star) });
        var fillCell = new Border { Height = barHeight, CornerRadius = new CornerRadius(barHeight / 2), Background = GaugeBrush(color, useGradient) };
        Grid.SetColumn(fillCell, 0);
        proportionalGrid.Children.Add(fillCell);
        grid.Children.Add(proportionalGrid);

        stack.Children.Add(grid);
        return stack;
    }
}
