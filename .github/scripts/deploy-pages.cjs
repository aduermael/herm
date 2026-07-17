const failureStatuses = new Set([
  'deployment_failed',
  'deployment_perms_error',
  'deployment_content_failed',
  'deployment_cancelled',
  'deployment_lost',
])

function pagesBuildVersion(context) {
  // Main and tag pushes can share a commit but produce different artifacts.
  // Pages requires a unique build version to deploy the second artifact.
  return `${context.sha}-${context.runId}-${context.runAttempt}`
}

async function deployPages({ github, context, core }, options = {}) {
  const artifactId = options.artifactId
  if (!Number.isSafeInteger(artifactId) || artifactId <= 0) {
    throw new Error(`Invalid github-pages artifact ID: ${artifactId}`)
  }
  const sleep = options.sleep || (ms => new Promise(resolve => setTimeout(resolve, ms)))
  const pollInterval = options.pollInterval || 5000
  const timeout = options.timeout || 10 * 60 * 1000
  const { owner, repo } = context.repo
  const buildVersion = pagesBuildVersion(context)

  const deployment = await github.request(
    'POST /repos/{owner}/{repo}/pages/deployments',
    {
      owner,
      repo,
      artifact_id: artifactId,
      pages_build_version: buildVersion,
      oidc_token: await core.getIDToken(),
    },
  )
  core.setOutput('page_url', deployment.data.page_url)

  const deploymentId = deployment.data.id || buildVersion
  const deadline = Date.now() + timeout
  let apiErrors = 0
  while (Date.now() < deadline) {
    await sleep(pollInterval)
    let statusResponse
    try {
      statusResponse = await github.request(
        'GET /repos/{owner}/{repo}/pages/deployments/{deploymentId}',
        { owner, repo, deploymentId },
      )
      apiErrors = 0
    } catch (error) {
      apiErrors += 1
      if (apiErrors >= 10) throw error
      core.warning(`Unable to read Pages deployment status: ${error.message}`)
      continue
    }

    const status = statusResponse.data.status
    if (status === 'succeed') {
      core.info(`Pages deployment ${buildVersion} succeeded`)
      return
    }
    if (failureStatuses.has(status)) {
      throw new Error(`Pages deployment failed with status: ${status}`)
    }
    core.info(`Pages deployment status: ${status}`)
  }
  throw new Error(`Pages deployment ${buildVersion} timed out`)
}

module.exports = deployPages
module.exports.pagesBuildVersion = pagesBuildVersion
