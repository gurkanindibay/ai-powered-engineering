import { Formatter } from '@cucumber/cucumber';
import type { IFormatterOptions } from '@cucumber/cucumber';
import * as messages from '@cucumber/messages';
import * as fs from 'fs';
import * as path from 'path';

export default class SitePulseFormatter extends Formatter {
  private gherkinDocuments: Map<string, messages.GherkinDocument> = new Map();
  private pickles: Map<string, messages.Pickle> = new Map();
  private testCases: Map<string, messages.TestCase> = new Map();
  private testCaseStarted: Map<string, { pickleId: string; timestamp: messages.Timestamp }> = new Map();
  private stepStarted: Map<string, messages.Timestamp> = new Map();
  private stepResults: Map<string, Array<{ keyword: string; text: string; status: string; duration_s: number }>> = new Map();
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
      const tc = this.testCases.get(envelope.testCaseStarted.testCaseId);
      if (tc) {
        this.testCaseStarted.set(envelope.testCaseStarted.id, {
          pickleId: tc.pickleId,
          timestamp: envelope.testCaseStarted.timestamp,
        });
        this.stepResults.set(envelope.testCaseStarted.id, []);
      }
    } else if (envelope.testStepStarted) {
      this.stepStarted.set(envelope.testStepStarted.testStepId, envelope.testStepStarted.timestamp);
    } else if (envelope.testStepFinished) {
      const tcStarted = this.testCaseStarted.get(envelope.testStepFinished.testCaseStartedId);
      const start = this.stepStarted.get(envelope.testStepFinished.testStepId);
      if (tcStarted && start) {
        const testCase = Array.from(this.testCases.values()).find(
          tc => tc.pickleId === tcStarted.pickleId
        );
        const testStep = testCase?.testSteps.find(ts => ts.id === envelope.testStepFinished?.testStepId);
        if (testStep && testStep.pickleStepId) {
          const pickle = this.pickles.get(tcStarted.pickleId);
          const pickleStep = pickle?.steps.find(s => s.id === testStep.pickleStepId);
          if (pickleStep) {
            const durationNanos =
              (envelope.testStepFinished.timestamp.seconds - start.seconds) * 1e9 +
              (envelope.testStepFinished.timestamp.nanos - start.nanos);
            const duration_s = Math.max(0, Math.round((durationNanos / 1e9) * 1000) / 1000);

            let status = 'PASS';
            if (envelope.testStepFinished.testStepResult.status !== messages.TestStepResultStatus.PASSED) {
              status = 'FAIL';
            }

            const stepKeyword = this.resolveStepKeyword(pickle?.uri || '', pickleStep.astNodeIds[0]) || 'Step';

            this.stepResults.get(envelope.testStepFinished.testCaseStartedId)?.push({
              keyword: stepKeyword,
              text: pickleStep.text,
              status,
              duration_s,
            });
          }
        }
      }
    } else if (envelope.testCaseFinished) {
      this.recordTestCase(envelope.testCaseFinished);
    }
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
    const started = this.testCaseStarted.get(finished.testCaseStartedId);
    if (!started) return;

    const pickle = this.pickles.get(started.pickleId);
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

    const steps = this.stepResults.get(finished.testCaseStartedId) || [];
    const isPass = steps.length > 0 && steps.every(s => s.status === 'PASS');

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
      error: '',
      gui_ids,
    };

    fs.mkdirSync(path.dirname(this.outputPath), { recursive: true });
    fs.appendFileSync(this.outputPath, JSON.stringify(record) + '\n', 'utf-8');
  }
}
