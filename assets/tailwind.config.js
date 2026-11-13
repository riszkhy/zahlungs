module.exports = {
  mode: 'jit',
  // The app is light only (data-theme="light" on every layout). Without this,
  // `dark:` utilities follow the device's setting and paint pale text on the
  // white cards of a device that prefers a dark theme.
  darkMode: 'class',
  content: [
    './js/**/*.js',
    '../lib/zahlungs_web.ex',
    '../lib/zahlungs_web/**/*.{ex,heex,eex}'
  ],
  // Material Design 3 tokens (assets/css/app.css :root), for the MD3 screens.
  theme: {
    extend: {
      colors: {
        'primary': 'var(--md-primary)',
        'on-primary': 'var(--md-on-primary)',
        'primary-container': 'var(--md-primary-container)',
        'on-primary-container': 'var(--md-on-primary-container)',
        'secondary': 'var(--md-secondary)',
        'on-secondary': 'var(--md-on-secondary)',
        'secondary-container': 'var(--md-secondary-container)',
        'on-secondary-container': 'var(--md-on-secondary-container)',
        'tertiary': 'var(--md-tertiary)',
        'on-tertiary': 'var(--md-on-tertiary)',
        'tertiary-container': 'var(--md-tertiary-container)',
        'on-tertiary-container': 'var(--md-on-tertiary-container)',
        'error': 'var(--md-error)',
        'on-error': 'var(--md-on-error)',
        'error-container': 'var(--md-error-container)',
        'on-error-container': 'var(--md-on-error-container)',
        'warning': 'var(--md-warning)',
        'on-warning': 'var(--md-on-warning)',
        'warning-container': 'var(--md-warning-container)',
        'on-warning-container': 'var(--md-on-warning-container)',
        'surface': 'var(--md-surface)',
        'on-surface': 'var(--md-on-surface)',
        'surface-container-lowest': 'var(--md-surface-container-lowest)',
        'on-surface-variant': 'var(--md-on-surface-variant)',
        'surface-container-low': 'var(--md-surface-container-low)',
        'outline': 'var(--md-outline)',
        'surface-container': 'var(--md-surface-container)',
        'outline-variant': 'var(--md-outline-variant)',
        'surface-container-high': 'var(--md-surface-container-high)',
        'inverse-surface': 'var(--md-inverse-surface)',
        'surface-container-highest': 'var(--md-surface-container-highest)',
        'inverse-on-surface': 'var(--md-inverse-on-surface)',
      },
      borderRadius: {
        'md3-xs': '4px',
        'md3-sm': '8px',
        'md3-md': '12px',
        'md3-lg': '16px',
        'md3-xl': '28px',
      },
      boxShadow: {
        'elev-1': '0 1px 2px rgba(0,0,0,.3), 0 1px 3px 1px rgba(0,0,0,.15)',
        'elev-2': '0 1px 2px rgba(0,0,0,.3), 0 2px 6px 2px rgba(0,0,0,.15)',
        'elev-3': '0 4px 8px 3px rgba(0,0,0,.15), 0 1px 3px rgba(0,0,0,.3)',
      },
      fontSize: {
        'headline-sm': ['24px', '32px'],
        'title-lg': ['22px', '28px'],
        'title-md': ['16px', { lineHeight: '24px', fontWeight: '500' }],
        'title-sm': ['14px', { lineHeight: '20px', fontWeight: '500' }],
        'body-lg': ['16px', '24px'],
        'body-md': ['14px', '20px'],
        'body-sm': ['12px', '16px'],
        'label-lg': ['14px', { lineHeight: '20px', fontWeight: '500' }],
        'label-md': ['12px', { lineHeight: '16px', fontWeight: '500' }],
      },
    },
  },
  plugins: [
    require('@tailwindcss/typography'),
    require('daisyui')
  ],
}
