/*
 * Create Headers Plugin
 *
 * @param id       - the identifier returned by the collector
 * @param content  - the output of your content plugin
 * @param options  - an object containing options. Options are sent from Java
 *
 * @return - an object of headers
 */
function createHeaders(id, content, options) {
  if (id === '/input-2.json' || id === '/input-2.xml') {
    xdmp.log('GOING BOOM');
    fn.error(xs.QName("BOOM"), "I BLEW UP");
  }
  return {};
}

module.exports = {
  createHeaders: createHeaders
};
