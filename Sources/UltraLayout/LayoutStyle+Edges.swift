import Foundation

// Flat accessors for the edge values, named the way style objects usually
// spell them: `style.marginTop = 8`, `style.paddingHorizontal = 12`,
// `style.top = 0`, `style.borderBottomWidth = 1`.

extension LayoutStyle {
    // MARK: Position offsets

    public var top: Dimension? {
        get { insets.top }
        set { insets.top = newValue }
    }

    public var left: Dimension? {
        get { insets.left }
        set { insets.left = newValue }
    }

    public var bottom: Dimension? {
        get { insets.bottom }
        set { insets.bottom = newValue }
    }

    public var right: Dimension? {
        get { insets.right }
        set { insets.right = newValue }
    }

    public var start: Dimension? {
        get { insets.start }
        set { insets.start = newValue }
    }

    public var end: Dimension? {
        get { insets.end }
        set { insets.end = newValue }
    }

    // MARK: Margin

    public var margin: Dimension? {
        get { margins.all }
        set { margins.all = newValue }
    }

    public var marginHorizontal: Dimension? {
        get { margins.horizontal }
        set { margins.horizontal = newValue }
    }

    public var marginVertical: Dimension? {
        get { margins.vertical }
        set { margins.vertical = newValue }
    }

    public var marginTop: Dimension? {
        get { margins.top }
        set { margins.top = newValue }
    }

    public var marginLeft: Dimension? {
        get { margins.left }
        set { margins.left = newValue }
    }

    public var marginBottom: Dimension? {
        get { margins.bottom }
        set { margins.bottom = newValue }
    }

    public var marginRight: Dimension? {
        get { margins.right }
        set { margins.right = newValue }
    }

    public var marginStart: Dimension? {
        get { margins.start }
        set { margins.start = newValue }
    }

    public var marginEnd: Dimension? {
        get { margins.end }
        set { margins.end = newValue }
    }

    // MARK: Padding

    public var padding: Dimension? {
        get { paddings.all }
        set { paddings.all = newValue }
    }

    public var paddingHorizontal: Dimension? {
        get { paddings.horizontal }
        set { paddings.horizontal = newValue }
    }

    public var paddingVertical: Dimension? {
        get { paddings.vertical }
        set { paddings.vertical = newValue }
    }

    public var paddingTop: Dimension? {
        get { paddings.top }
        set { paddings.top = newValue }
    }

    public var paddingLeft: Dimension? {
        get { paddings.left }
        set { paddings.left = newValue }
    }

    public var paddingBottom: Dimension? {
        get { paddings.bottom }
        set { paddings.bottom = newValue }
    }

    public var paddingRight: Dimension? {
        get { paddings.right }
        set { paddings.right = newValue }
    }

    public var paddingStart: Dimension? {
        get { paddings.start }
        set { paddings.start = newValue }
    }

    public var paddingEnd: Dimension? {
        get { paddings.end }
        set { paddings.end = newValue }
    }

    // MARK: Border widths

    public var borderWidth: CGFloat? {
        get { borderWidths.all }
        set { borderWidths.all = newValue }
    }

    public var borderTopWidth: CGFloat? {
        get { borderWidths.top }
        set { borderWidths.top = newValue }
    }

    public var borderLeftWidth: CGFloat? {
        get { borderWidths.left }
        set { borderWidths.left = newValue }
    }

    public var borderBottomWidth: CGFloat? {
        get { borderWidths.bottom }
        set { borderWidths.bottom = newValue }
    }

    public var borderRightWidth: CGFloat? {
        get { borderWidths.right }
        set { borderWidths.right = newValue }
    }

    public var borderStartWidth: CGFloat? {
        get { borderWidths.start }
        set { borderWidths.start = newValue }
    }

    public var borderEndWidth: CGFloat? {
        get { borderWidths.end }
        set { borderWidths.end = newValue }
    }
}
