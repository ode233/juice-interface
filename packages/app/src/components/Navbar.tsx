import { JsonRpcProvider } from '@ethersproject/providers'

import Account from './Account'

export default function Navbar({
  providerAddress,
  hasBudget,
  userProvider,
  onConnectWallet,
}: {
  providerAddress?: string
  hasBudget?: boolean
  userProvider?: JsonRpcProvider
  onConnectWallet: VoidFunction
}) {
  const menuItem = (text: string, route: string) => (
    <a
      style={{ textDecoration: 'none', fontWeight: 600, color: 'black' }}
      href={route}
    >
      {text}
    </a>
  )

  return (
    <div
      style={{
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'space-between',
        padding: '6px 20px',
        borderBottom: '1px solid lightgrey',
      }}
    >
      <span
        style={{
          display: 'grid',
          gridAutoFlow: 'column',
          columnGap: 20,
          alignItems: 'center',
        }}
      >
        <a href="/">
          <img
            style={{ height: 32 }}
            src="/assets/juice_logo-ol.png"
            alt="Juice logo"
          />
        </a>
        {providerAddress
          ? menuItem(
              hasBudget ? 'Your project' : 'Start a project',
              providerAddress,
            )
          : null}
      </span>
      <Account
        userProvider={userProvider}
        loadWeb3Modal={onConnectWallet}
        providerAddress={providerAddress}
      />
    </div>
  )
}