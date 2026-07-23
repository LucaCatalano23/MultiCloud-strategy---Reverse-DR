import '@testing-library/jest-dom/vitest'
import { cleanup } from '@testing-library/react'
import { afterEach } from 'vitest'

afterEach(() => {
  cleanup()
  document.cookie = '__Host-helios_csrf=; Max-Age=0; Secure; path=/'
})
