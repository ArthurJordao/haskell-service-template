const getToken = () => localStorage.getItem('access_token')

export async function apiFetch<T>(baseUrl: string, path: string, init: RequestInit = {}): Promise<T> {
  const token = getToken()
  const headers: HeadersInit = {
    'Content-Type': 'application/json',
    ...(token ? { Authorization: `Bearer ${token}` } : {}),
    ...(init.headers ?? {}),
  }

  const res = await fetch(`${baseUrl}${path}`, { ...init, headers })

  if (!res.ok) {
    const body = await res.text().catch(() => res.statusText)
    throw new Error(`${res.status}: ${body}`)
  }

  if (res.status === 204) return undefined as T
  return res.json() as Promise<T>
}
