/// The colors a player can pick when joining a world ("#RRGGBB"). Saturated
/// enough to stand out on the pale land.
///
/// Laid out in rows of 7 (the join screen fits 7 swatches per row), grouped
/// by hue: reds/oranges, yellows/greens, teals/cyans, blues/violets,
/// pinks/magentas, then browns/greys.
const List<String> playerColorChoices = [
  // reds / oranges
  '#E63946', // red
  '#C1121F', // crimson
  '#9D0208', // dark red
  '#E76F51', // orange
  '#F4511E', // vivid orange
  '#D2691E', // cinnamon
  '#E9A23B', // amber
  // yellows / greens
  '#F2C14E', // gold
  '#C9A227', // mustard
  '#8AB17D', // sage
  '#6A994E', // green
  '#3A7D44', // forest
  '#2D6A4F', // deep green
  '#8F9E2B', // olive
  // teals / cyans
  '#2A9D8F', // teal
  '#168A7A', // dark teal
  '#00A6A6', // turquoise
  '#0097B2', // cyan
  '#3FA7D6', // sky blue
  '#457B9D', // steel blue
  '#2B6A99', // ocean
  // blues / violets
  '#4361EE', // blue
  '#3A0CA3', // indigo
  '#1D3A8A', // navy
  '#5C6BC0', // periwinkle
  '#7B2CBF', // purple
  '#9D4EDD', // violet
  '#5A189A', // deep purple
  // pinks / magentas
  '#B5179E', // magenta
  '#E56B9B', // pink
  '#F72585', // hot pink
  '#D81B60', // raspberry
  '#880E4F', // wine
  '#C77DFF', // lavender
  '#A64D79', // mauve
  // browns / greys
  '#6D4C41', // brown
  '#8D6E63', // taupe
  '#A0522D', // sienna
  '#5D4037', // dark brown
  '#343A40', // charcoal
  '#607D8B', // slate
  '#78909C', // blue grey
];