# Mini App Starter

A minimal counter mini app starter built with Next.js and Movement SDK. A simple on-chain counter... modify it to create your Mini App!

## Features

- Simple on-chain counter
- Increment and reset functions
- Clean, minimal design with lots of space
- Movement Design System integration
- Wallet connection and SDK initialization

## Getting Started

1. Install dependencies:
```bash
npm install
# or
pnpm install
```

2. Deploy the Move contract:
```bash
cd move
# Deploy using your preferred Move tooling
# Update COUNTER_MODULE_ADDRESS in constants.ts with your deployed address
```

3. Update the contract address in `constants.ts`:
```typescript
export const COUNTER_MODULE_ADDRESS = "0x..."; // Your deployed address
```

4. Run the development server:
```bash
npm run dev
# or
pnpm dev
```

5. Open [http://localhost:3000](http://localhost:3000) in your browser.

## Contract Functions

- `initialize()` - Initialize counter resource (one-time setup)
- `increment()` - Increment counter by 1
- `reset()` - Reset counter to 0
- `get_value(address)` - View function to read counter value

## Project Structure

```
mini-app-starter/
├── move/              # Move smart contract
│   ├── sources/
│   │   └── counter.move
│   └── Move.toml
├── src/
│   └── app/
│       ├── page.tsx   # Main counter page
│       ├── layout.tsx
│       └── globals.css
├── constants.ts       # Contract address
└── package.json
```

