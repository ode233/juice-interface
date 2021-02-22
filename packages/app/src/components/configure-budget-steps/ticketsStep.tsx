import { FormInstance } from 'antd'
import React from 'react'

import { TicketsFormFields } from '../../models/forms-fields/tickets-form'
import { Step } from '../../models/step'
import TicketsForm from '../forms/TicketsForm'

export function ticketsStep({
  form,
  ticketsInitialized,
}: {
  form: FormInstance<TicketsFormFields>
  ticketsInitialized?: boolean
}): Step {
  return {
    title: 'Tickets (optional)',
    content: (
      <TicketsForm
        props={{ form }}
        header={
          <div>
            <h2>Create your ERC-20 ticket token</h2>
            <p>
              You can always do this later. Your contract will use I-Owe-You
              tickets in the meantime.
            </p>
          </div>
        }
        disabled={ticketsInitialized}
      />
    ),
    info: [
      'Your contract will use these ERC-20 tokens like tickets, handing them out to people as a receipt for payments received.',
      "Tickets can be redeemed for your contract's overflow on a bonding curve – a ticket is redeemable for 38.2% of its proportional overflowed tokens. Meaning, if there are 100 overflow tokens available and 100 of your tickets in circulation, 10 tickets could be redeemed for 3.82 of the overflow tokens. The rest is left to share between the remaining ticket hodlers.",
      '---',
      "You can propose reconfigurations to your contract's specs at any time. Your ticket holders will have 3 days to vote yay or nay. If there are more yays than nays, the new specs will be used once the active budgeting period expires.",
    ],
  }
}