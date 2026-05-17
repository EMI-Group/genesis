/**
 * This is about the same
 * var html = new DOMParser().parseFromString(str, 'text/html');
 * return html.body.firstChild;
 *
 * @method toElement
 * @param {String} str
 */
export function toElement(str: string): any;
/**
 * Returns true if two node's names are the same.
 *
 * NOTE: We don't bother checking `namespaceURI` because you will never find two HTML elements with the same
 *       nodeName and different namespace URIs.
 *
 * @param {Element} fromEl
 * @param {Element} toEl The target element
 * @return {boolean}
 */
export function compareNodeNames(fromEl: Element, toEl: Element): boolean;
/**
 * Create an element, optionally with a known namespace URI.
 *
 * @param {string} name the element name, e.g. 'div' or 'svg'
 * @param {string} [namespaceURI] the element's namespace URI, i.e. the value of
 * its `xmlns` attribute or its inferred namespace.
 *
 * @return {Element}
 */
export function createElementNS(name: string, namespaceURI?: string): Element;
/**
 * Copies the children of one DOM element to another DOM element
 */
export function moveChildren(fromEl: any, toEl: any): any;
export const doc: Document;
