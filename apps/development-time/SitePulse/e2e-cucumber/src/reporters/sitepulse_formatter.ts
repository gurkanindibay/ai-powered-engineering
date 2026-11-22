import { Formatter } from '@cucumber/cucumber';
import type { IFormatterOptions } from '@cucumber/cucumber';
import * as messages from '@cucumber/messages';
import * as fs from 'fs';
import * as path from 'path';

interface StepRecord {
  keyword: string;
  text: string;
  status: string;
  duration_s: number;
}

interface TestCaseAttempt {
  testCase: messages.TestCase;
  timestamp: messages.Timestamp;
  results: messages.TestStepResult[];
  steps: StepRecord[];
}

export default class SitePulseFormatter extends Formatter {
  private gherkinDocuments: Map<string, messages.GherkinDocument> = new Map();
  private pickles: Map<string, messages.Pickle> = new Map();
  private testCases: Map<string, messages.TestCase> = new Map();
  private attempts = new Map<string, TestCaseAttempt>();
  private outputPath: string;

  constructor(options: IFormatterOptions) {
    super(options);
    this.outputPath = process.env.SITEPULSE_EXECUTION_RECORDS ||
      (options.parsedArgvOptions && (options.parsedArgvOptions as any).sitepulse) ||
      path.resolve(process.cwd(), 'target/executions.jsonl');

    options.eventBroadcaster.on('envelope', (envelope: messages.Envelope) => {
      this.handleEnvelope(envelope);
    });
  }

  private handleEnvelope(envelope: messages.Envelope): void {
    if (envelope.gherkinDocument) {
      if (envelope.gherkinDocument.uri) {
        this.gherkinDocuments.set(envelope.gherkinDocument.uri, envelope.gherkinDocument);
      }
    } else if (envelope.pickle) {
      this.pickles.set(envelope.pickle.id, envelope.pickle);
    } else if (envelope.testCase) {
      this.testCases.set(envelope.testCase.id, envelope.testCase);
    } else if (envelope.testCaseStarted) {
      const { id, testCaseId, timestamp } = envelope.testCaseStarted;
      const testCase = this.testCases.get(testCaseId);
      if (testCase) {
        this.attempts.set(id, { testCase, timestamp, results: [], steps: [] });
      }
    } else if (envelope.testStepFinished) {
      this.recordTestStep(envelope.testStepFinished);
    } else if (envelope.testCaseFinished) {
      this.recordTestCase(envelope.testCaseFinished);
    }
  }

  private recordTestStep(finished: messages.TestStepFinished): void {
    const attempt = this.attempts.get(finished.testCaseStartedId);
    if (!attempt) return;

    const result = finished.testStepResult;
    attempt.results.push(result);

    const testStep = attempt.testCase.testSteps.find(step => step.id === finished.testStepId);
    const pickle = this.pickles.get(attempt.testCase.pickleId);
    const pickleStep = pickle?.steps.find(step => step.id === testStep?.pickleStepId);
    if (!pickle || !pickleStep) return;

    const { seconds, nanos } = result.duration;
    attempt.steps.push({
      keyword: this.resolveStepKeyword(pickle.uri, pickleStep.astNodeIds[0]) || 'Step',
      text: pickleStep.text,
      status: result.status === messages.TestStepResultStatus.PASSED ? 'PASS' : 'FAIL',
      duration_s: seconds + Math.round(nanos / 1e6) / 1000,
    });
  }

  private resolveStepKeyword(uri: string, astNodeId: string): string | undefined {
    const doc = this.gherkinDocuments.get(uri);
    if (!doc || !doc.feature) return undefined;

    for (const child of doc.feature.children) {
      if (child.scenario) {
        for (const step of child.scenario.steps) {
          if (step.id === astNodeId) return step.keyword.trim();
        }
      }
      if (child.background) {
        for (const step of child.background.steps) {
          if (step.id === astNodeId) return step.keyword.trim();
        }
      }
    }
    return undefined;
  }

  private recordTestCase(finished: messages.TestCaseFinished): void {
    const started = this.attempts.get(finished.testCaseStartedId);
    if (!started) return;
    this.attempts.delete(finished.testCaseStartedId);

    const pickle = this.pickles.get(started.testCase.pickleId);
    if (!pickle) return;

    const uri = pickle.uri || '';
    const doc = this.gherkinDocuments.get(uri);

    const tags = pickle.tags.map(t => t.name);
    const epic = tags.find(t => t.startsWith('@EPIC-'))?.substring(1) || '';
    const story = tags.find(t => t.startsWith('@STORY-'))?.substring(1) || '';
    const scenario = tags.find(t => t.startsWith('@SC-'))?.substring(1) || '';
    const gui_ids = tags.filter(t => t.startsWith('@GUI-')).map(t => t.substring(1));
    const layer = tags.find(t => t.startsWith('@layer:'))?.substring(7) || 'gui';

    // Example resolution for scenario outlines
    let example: Record<string, string> | null = null;
    let example_row: number | null = null;
    let example_id = scenario;

    const astNodeId = pickle.astNodeIds[pickle.astNodeIds.length - 1];
    if (doc?.feature) {
      for (const child of doc.feature.children) {
        if (child.scenario && child.scenario.examples) {
          for (const ex of child.scenario.examples) {
            const rowIndex = ex.tableBody.findIndex(row => row.id === astNodeId);
            if (rowIndex >= 0) {
              example_row = rowIndex + 1;
              example_id = `${scenario}[${example_row}]`;
              example = {};
              const header = ex.tableHeader?.cells.map(c => c.value) || [];
              const cells = ex.tableBody[rowIndex].cells.map(c => c.value);
              header.forEach((k, idx) => {
                if (example) example[k] = cells[idx] || '';
              });
            }
          }
        }
      }
    }

    const durationNanos =
      (finished.timestamp.seconds - started.timestamp.seconds) * 1e9 +
      (finished.timestamp.nanos - started.timestamp.nanos);
    const duration_s = Math.max(0, Math.round((durationNanos / 1e9) * 1000) / 1000);

    const { results, steps } = started;
    const failures = results.filter(result => result.status !== messages.TestStepResultStatus.PASSED);
    const isPass = results.length > 0 && failures.length === 0;
    const error = failures.map(result => result.message).filter(Boolean).join('\n');

    const featureRel = path.relative(path.resolve(process.cwd(), '../.specify/features'), uri).replace(/\\/g, '/');

    const record = {
      epic,
      story,
      scenario,
      name: pickle.name,
      binding: 'gherkin',
      layer,
      feature_file: featureRel.includes('EPIC-') ? featureRel.substring(featureRel.indexOf('EPIC-')) : featureRel,
      example,
      example_row,
      example_id,
      test: `${uri}:${pickle.name}${example_row ? ` [${example_row}]` : ''}`,
      status: isPass ? 'PASS' : 'FAIL',
      duration_s,
      steps,
      error,
      gui_ids,
    };

    fs.mkdirSync(path.dirname(this.outputPath), { recursive: true });
    fs.appendFileSync(this.outputPath, JSON.stringify(record) + '\n', 'utf-8');
  }
}
