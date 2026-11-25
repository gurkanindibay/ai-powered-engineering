import { configure } from '@serenity-js/core';
import * as path from 'path';

console.log('=== SERENITY CONFIG LOADED ===');

configure({
  crew: [
    [ '@serenity-js/serenity-bdd', {
        specDirectory: path.resolve(process.cwd(), '../.specify/features'),
    } ],
    [ '@serenity-js/core:ArtifactArchiver', {
        outputDirectory: path.resolve(process.cwd(), 'target/site/serenity'),
    } ],
  ],
});

