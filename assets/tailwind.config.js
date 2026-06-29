module.exports = {
  mode: 'jit',
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
