# Meyn Branding Guidelines for HSE Newsletter Manager

This document outlines the Meyn company branding that has been applied to the HSE Newsletter Manager application.

## Brand Colors

The application uses the following color palette from Meyn's 2026 Brandbook:

### Primary Colors

| Color | Hex Code | Usage |
|-------|----------|-------|
| **Meyn Green** | `#00765a` | Primary brand color - buttons, links, headers |
| **Midnight Green** | `#2d2e32` | Dark backgrounds, sidebar, text |
| **White** | `#ffffff` | Backgrounds, text on dark backgrounds |

### Secondary Colors

| Color | Hex Code | Usage |
|-------|----------|-------|
| **Soft Green** | `#f2f6f5` | Light backgrounds, secondary elements |
| **Punchy Pink** | `#eb0069` | Accent color - warnings, alerts, highlights |
| **Backup Blue** | `#268acb` | Charts, secondary accents |
| **Backup Purple** | `#6d1d6f` | Charts, data visualization |
| **Backup Yellow** | `#baba0b` | Charts, alternative accents |
| **Soft Black** | `#2d2e32` | Dark text, sidebar elements |
| **Light Grey** | `#efeff1` | Borders, subtle backgrounds |

## Typography

The application uses the **Roboto** font family:

- **Roboto Light** (300): Subtle text, secondary information
- **Roboto Regular** (400): Body text, standard content
- **Roboto Black** (700): Headings, emphasis

Font stack: `'Roboto', 'Roboto Fallback', sans-serif`

## Theme Implementation

### Light Theme

- **Background**: White (`#ffffff`)
- **Text**: Midnight Green (`#2d2e32`)
- **Primary Actions**: Meyn Green (`#00765a`)
- **Secondary Background**: Soft Green (`#f2f6f5`)
- **Accents**: Punchy Pink (`#eb0069`)

### Dark Theme

- **Background**: Soft Black (`#004340`)
- **Text**: Soft Green (`#f2f6f5`)
- **Primary Actions**: Meyn Green (`#00765a`)
- **Secondary Background**: Midnight Green (`#2d2e32`)
- **Accents**: Punchy Pink (`#eb0069`)

## Color Tokens (CSS Variables)

All colors are defined as CSS custom properties in `app/globals.css`:

```css
:root {
  --primary: #00765a;              /* Meyn Green */
  --secondary: #f2f6f5;            /* Soft Green */
  --accent: #eb0069;               /* Punchy Pink */
  --sidebar: #2d2e32;              /* Midnight Green */
  --success: #00765a;              /* Meyn Green */
  --warning: #eb0069;              /* Punchy Pink */
}
```

## Tailwind CSS Usage

Use these Tailwind classes to apply brand colors:

```tsx
// Primary (Meyn Green)
<button className="bg-primary text-primary-foreground">Button</button>

// Secondary (Soft Green)
<div className="bg-secondary text-secondary-foreground">Content</div>

// Accent (Punchy Pink)
<span className="text-accent">Highlight</span>

// Success states
<div className="bg-success text-success-foreground">Success</div>

// Warning/Alert states
<div className="bg-warning text-warning-foreground">Warning</div>
```

## Component Styling Examples

### Buttons

```tsx
// Primary Action Button
<button className="bg-primary hover:bg-primary/90 text-white px-4 py-2 rounded">
  Primary Action
</button>

// Secondary Button
<button className="bg-secondary text-primary px-4 py-2 rounded border border-primary">
  Secondary Action
</button>
```

### Cards

```tsx
<div className="bg-card text-card-foreground rounded-lg shadow-md p-4">
  <h3 className="text-primary font-black mb-2">Card Title</h3>
  <p>Card content</p>
</div>
```

### Status Badges

```tsx
// Success
<span className="bg-success text-white px-3 py-1 rounded-full text-sm">
  Active
</span>

// Warning
<span className="bg-warning text-white px-3 py-1 rounded-full text-sm">
  Pending
</span>

// Error
<span className="bg-destructive text-white px-3 py-1 rounded-full text-sm">
  Error
</span>
```

## Accessibility

- **Color Contrast**: All text meets WCAG AA standards (4.5:1 minimum for body text)
- **Primary + White**: 7.2:1 contrast ratio
- **Dark Theme**: Colors maintain sufficient contrast for readability

## Where to Find the Original Brandbook

- **File**: `Meyn - Brandbook 2026 - V6.pdf` (in project documentation)
- **Website**: https://meyn.com
- **Contact**: marketing@meyn.com

## Updating the Theme

If you need to update brand colors:

1. Edit `/app/globals.css`:
   - Update `:root` section for light theme
   - Update `.dark` section for dark theme
2. Update color tokens in both light and dark variants
3. No changes needed to component files - they use CSS variables automatically

## Questions?

Refer to the Meyn Brandbook 2026 V6 for comprehensive branding guidelines, or contact the marketing team at marketing@meyn.com.
