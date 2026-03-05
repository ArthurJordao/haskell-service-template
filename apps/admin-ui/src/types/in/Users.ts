export interface ScopeInfo {
  id: number
  name: string
  description: string
}

export interface UserWithScopes {
  id: number
  email: string
  scopes: string[]
}
