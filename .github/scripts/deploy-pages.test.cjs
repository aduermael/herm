const assert = require('node:assert/strict')
const test = require('node:test')
const deployPages = require('./deploy-pages.cjs')

function harness(contextOverrides = {}) {
  const requests = []
  const outputs = []
  const context = {
    repo: { owner: 'aduermael', repo: 'herm' },
    sha: '8e94d354e1ecccbf297753b1fa5babc787aeb637',
    runId: 100,
    runAttempt: 1,
    ...contextOverrides,
  }
  return {
    context,
    requests,
    outputs,
    github: {
      request: async (route, parameters) => {
        requests.push({ route, parameters })
        if (route.startsWith('POST')) {
          return { data: { id: parameters.pages_build_version, page_url: 'https://example.test' } }
        }
        return { data: { status: 'succeed' } }
      },
    },
    core: {
      getIDToken: async () => 'oidc-token',
      setOutput: (name, value) => outputs.push({ name, value }),
      info: () => {},
      warning: () => {},
    },
  }
}

test('build version differs for main and tag runs of the same commit', () => {
  const main = harness({ runId: 100 }).context
  const tag = harness({ runId: 101 }).context

  assert.notEqual(
    deployPages.pagesBuildVersion(main),
    deployPages.pagesBuildVersion(tag),
  )
})

test('deploys the current run artifact with its unique build version', async () => {
  const run = harness()

  await deployPages(run, { artifactId: 42, sleep: async () => {} })

  assert.equal(run.requests[0].parameters.artifact_id, 42)
  assert.equal(
    run.requests[0].parameters.pages_build_version,
    '8e94d354e1ecccbf297753b1fa5babc787aeb637-100-1',
  )
  assert.deepEqual(run.outputs, [{ name: 'page_url', value: 'https://example.test' }])
})
