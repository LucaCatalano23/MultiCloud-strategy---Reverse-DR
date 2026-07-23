import { describe, expect, it, vi } from 'vitest'
import { loadRuntimeConfig, parseRuntimeConfig } from './runtimeConfig'

describe('runtime config', () => {
  it('loads the same-origin bootstrap without caching credentials elsewhere', async () => {
    const fetcher = vi.fn().mockResolvedValue({
      ok: true,
      json: () =>
        Promise.resolve({
          appName: 'Helios Desk',
          apiBasePath: '/api/v1',
          demoMode: false,
        }),
    })

    await expect(loadRuntimeConfig(fetcher)).resolves.toMatchObject({
      apiBasePath: '/api/v1',
      demoMode: false,
    })
    expect(fetcher).toHaveBeenCalledWith('/config/runtime-config.json', {
      cache: 'no-store',
      credentials: 'same-origin',
      headers: { Accept: 'application/json' },
    })
  })

  it('rejects an absolute API URL to preserve the BFF same-origin boundary', () => {
    expect(() =>
      parseRuntimeConfig({
        appName: 'Helios Desk',
        apiBasePath: 'https://api.example.test/api/v1',
        demoMode: false,
      }),
    ).toThrow(/same-origin/i)
  })

  it('fails closed when demo mode is omitted', () => {
    expect(() =>
      parseRuntimeConfig({
        appName: 'Helios Desk',
        apiBasePath: '/api/v1',
      }),
    ).toThrow(/demoMode/)
  })
})
