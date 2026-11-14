const DEFAULT_HEIGHT = 640

class DocusealEmbed extends HTMLElement {
  connectedCallback () {
    if (this.iframe) return

    const src = this.dataset.src

    if (!src) {
      console.warn('docuseal: data-src attribute is required')

      return
    }

    const url = new URL(src, window.location.href)

    url.searchParams.set('embed', 'true')

    this.queryParam('email', 'email', url)
    this.queryParam('name', 'name', url)
    this.queryParam('phone', 'phone', url)
    this.queryParam('role', 'role', url)
    this.queryParam('lang', 'language', url)
    this.queryParam('completed_redirect_url', 'completedRedirectUrl', url)

    const height = parseInt(this.dataset.height || '', 10)
    const iframe = document.createElement('iframe')

    iframe.src = url.toString()
    iframe.loading = 'lazy'
    iframe.title = this.dataset.title || 'Document signing form'
    iframe.setAttribute('allow', 'clipboard-write')
    iframe.style.cssText = [
      'width: 100%',
      'border: 0',
      'display: block',
      `min-height: ${Number.isFinite(height) ? height : DEFAULT_HEIGHT}px`
    ].join(';')

    if (Number.isFinite(height)) {
      iframe.style.height = `${height}px`
    }

    this.appendChild(iframe)

    this.iframe = iframe
    this.onMessage = (event) => {
      if (event.source !== iframe.contentWindow) return
      if (event.data?.type !== 'docuseal:resize') return

      const nextHeight = Number(event.data.height)

      if (Number.isFinite(nextHeight) && nextHeight > 0) {
        iframe.style.height = `${Math.ceil(nextHeight)}px`
      }
    }

    window.addEventListener('message', this.onMessage)
  }

  disconnectedCallback () {
    if (this.onMessage) window.removeEventListener('message', this.onMessage)

    this.iframe?.remove()
    this.iframe = null
  }

  queryParam (param, key, url) {
    const value = this.dataset[key]

    if (value) url.searchParams.set(param, value)
  }
}

class DocusealForm extends DocusealEmbed {}

class DocusealBuilder extends DocusealEmbed {}

const define = (name, element) => {
  if (!window.customElements.get(name)) window.customElements.define(name, element)
}

define('docuseal-form', DocusealForm)
define('docuseal-builder', DocusealBuilder)
