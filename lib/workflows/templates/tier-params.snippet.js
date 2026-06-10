// lib/workflows/templates/tier-params.snippet.js
function expandTierParams(tier) {
  const matrix = {
    quality:  { refuteVoters: 5, planAngles: 5, dimensionReviewers: 4, completenessCritic: true },
    balanced: { refuteVoters: 3, planAngles: 3, dimensionReviewers: 3, completenessCritic: true },
    quick:    { refuteVoters: 1, planAngles: 1, dimensionReviewers: 1, completenessCritic: false },
  }
  return matrix[tier] || matrix.balanced
}
