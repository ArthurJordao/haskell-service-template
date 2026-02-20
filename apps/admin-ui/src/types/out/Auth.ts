export interface LoginRequest {
  email: string
  password: string
}

export interface RefreshRequest {
  refreshToken: string
}
