# Haskell Service Template

A monorepo template for building microservices in Haskell using Stack.

## Structure

```
haskell-service-template/
├── packages/
│   └── haskell-service-lib/    # Shared library for common functionality
└── services/
    └── account-service/         # Example account management service
```

## Shared Library

`haskell-service-lib` provides common infrastructure for all services:

- **Kafka** - Producer/consumer with correlation ID propagation
- **Database** - Connection pooling and configuration
- **Server** - HTTP server configuration
- **Correlation ID** - Request tracking and structured logging
- **Testing** - Mock Kafka infrastructure

## Building

Build all packages:

```bash
stack build
```

Build specific package:

```bash
stack build account-service
```

## Running Services

```bash
stack exec account-service-exe
```

## Testing

Run all tests:

```bash
stack test
```

Run specific package tests:

```bash
stack test account-service
stack test haskell-service-lib
```

## Adding New Services

1. Create a new directory under `services/`
2. Add the service path to `stack.yaml` packages list
3. Create `package.yaml` with dependency on `haskell-service-lib`
4. Import common functionality from the library

## Configuration

Services use environment variables for configuration. See each service's README for specific variables.

Common configuration is provided by `haskell-service-lib`:
- Database settings (`Service.Database`)
- HTTP server settings (`Service.Server`)
- Kafka settings (`Service.Kafka`)
