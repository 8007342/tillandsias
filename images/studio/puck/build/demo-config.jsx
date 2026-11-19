// @trace order:1864-ay3x, order:2110-pk4s
// The config the image-time editor uses when the site has no puck.config of
// its own (build-site.mjs builds against the site's config when it has one).
export default {
  components: {
    Heading: {
      fields: { title: { type: "text" } },
      defaultProps: { title: "Heading" },
      render: ({ title }) => <h1>{title}</h1>,
    },
    Paragraph: {
      fields: { text: { type: "textarea" } },
      defaultProps: { text: "Text" },
      render: ({ text }) => <p>{text}</p>,
    },
  },
};
