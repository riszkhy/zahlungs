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
  plugins: [
    require('@tailwindcss/typography'),
    require('daisyui')
  ],
}
