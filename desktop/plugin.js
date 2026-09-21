// GBrain — Hermes Desktop UI (unified package side).
// Desktop plugins load UNCOMPILED: JSX via jsx()/jsxs() from react/jsx-runtime;
// only @hermes/plugin-sdk, react, react/jsx-runtime may be imported.
// Optional starter UI — delete the `desktop/` folder if not needed.
import { host, useValue } from '@hermes/plugin-sdk'
import { jsx, jsxs } from 'react/jsx-runtime'

function GBrainPane() {
  const gateway = useValue(host.state.gateway)
  return jsxs('div', {
    className: 'flex h-full flex-col gap-2 p-3 text-sm',
    children: [
      jsx('div', { className: 'font-medium', children: 'GBrain — memory layer' }),
      jsx('div', {
        className: 'text-(--ui-text-tertiary)',
        children:
          'A persistent brain for the agent: synthesis, knowledge graph, gap analysis. Connected via MCP (gbrain serve). Setup/update: scripts/ in the hermes-gbrain plugin.',
      }),
      jsx('div', { className: 'text-(--ui-text-tertiary)', children: `gateway: ${gateway}` }),
      jsx('div', {
        className: 'mt-auto text-(--ui-text-tertiary)',
        children: 'v1.2.1 · kerrz2020/hermes-gbrain · upstream: garrytan/gbrain (MIT)',
      }),
    ],
  })
}

export default {
  id: 'gbrain-plugin',
  name: 'GBrain',
  defaultEnabled: true,
  register(ctx) {
    ctx.register({
      id: 'pane',
      area: 'panes',
      title: 'gbrain',
      data: { placement: 'right', width: '260px' },
      render: () => jsx(GBrainPane, {}),
    })
    ctx.register({
      id: 'chip',
      area: 'statusBar.right',
      order: 140,
      render: () =>
        jsx('button', {
          type: 'button',
          className: 'px-1.5 text-[0.6875rem] text-(--ui-text-tertiary)',
          onClick: () =>
            host.notify({
              kind: 'info',
              message: 'GBrain active — memory layer via MCP (gbrain serve)',
            }),
          children: 'gbrain',
        }),
    })
  },
}