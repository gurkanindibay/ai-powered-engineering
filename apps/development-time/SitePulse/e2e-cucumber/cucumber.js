module.exports = {
  default: {
    paths: [
      '../.specify/features/EPIC-10/STORY-10-01-capital-project-creation.feature',
      '../.specify/features/EPIC-10/STORY-10-04-inter-ledger-virman.feature',
      '../.specify/features/EPIC-07/STORY-07-06-site-bank-account-configuration.feature',
    ],
    // Only the four pilot scenarios are bound; the rest of these files stay with the pytest-bdd suite.
    tags: '@SC-10-01-01 or @SC-10-04-01 or @SC-10-04-02 or @SC-07-06-03',
    require: [
      'src/support/serenity.config.ts',
      'src/support/custom_world.ts',
      'src/steps/**/*.ts',
    ],
    requireModule: ['ts-node/register'],
    format: [
      ['@serenity-js/cucumber', 'target/serenity.log'],
      'progress',
      'summary',
      ['junit', 'target/junit-report.xml'],
      ['./src/reporters/sitepulse_formatter.ts', 'target/executions.jsonl'],
    ],
    formatOptions: {
      specDirectory: '../.specify/features',
    },
  },
};
