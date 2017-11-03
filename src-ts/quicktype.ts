import * as fs from "fs";
import * as path from "path";
import * as process from "process";

import * as Maybe from "Data.Maybe";

// These are simplified, uncurried versions of Either.fromRight, etc.
import { fromRight } from "./purescript";

import * as _ from "lodash";

import * as Main from "Main";
import { Config } from "Config";
import * as Renderers from "Language.Renderers";
import { ErrorMessage, SourceCode } from "Core";
import * as targetLanguages from "./Language/All";
import { OptionDefinition } from "./RendererOptions";
import { TargetLanguage } from "./TargetLanguage";
import { SerializedRenderResult, Annotation } from "./Source";
import { IssueAnnotationData } from "./Annotation";
import { readGraphQLSchema } from "./GraphQL";

const makeSource = require("stream-json");
const Assembler = require("stream-json/utils/Assembler");
const commandLineArgs = require("command-line-args");
const getUsage = require("command-line-usage");
const fetch = require("node-fetch");
const chalk = require("chalk");

const langs = targetLanguages.all.map(r => _.minBy(r.names, s => s.length)).join("|");
const langDisplayNames = targetLanguages.all.map(r => r.displayName).join(", ");

const optionDefinitions: OptionDefinition[] = [
    {
        name: "out",
        alias: "o",
        type: String,
        typeLabel: `FILE`,
        description: "The output file. Determines --lang and --top-level."
    },
    {
        name: "top-level",
        alias: "t",
        type: String,
        typeLabel: "NAME",
        description: "The name for the top level type."
    },
    {
        name: "lang",
        alias: "l",
        type: String,
        typeLabel: langs,
        description: "The target language."
    },
    {
        name: "src-lang",
        alias: "s",
        type: String,
        defaultValue: "json",
        typeLabel: "json|schema",
        description: "The source language (default is json)."
    },
    {
        name: "src",
        type: String,
        multiple: true,
        defaultOption: true,
        typeLabel: "FILE|URL|DIRECTORY",
        description: "The file, url, or data directory to type."
    },
    {
        name: "src-urls",
        type: String,
        typeLabel: "FILE",
        description: "Tracery grammar describing URLs to crawl."
    },
    {
        name: "graphql",
        type: String,
        typeLabel: "FILE",
        description: "GraphQL introspection file."
    },
    {
        name: "no-maps",
        type: Boolean,
        description: "Don't infer maps, always use classes."
    },
    {
        name: "quiet",
        type: Boolean,
        description: "Don't show issues in the generated code."
    },
    {
        name: "help",
        alias: "h",
        type: Boolean,
        description: "Get some help."
    }
];

interface UsageSection {
    header?: string;
    content?: string | string[];
    optionList?: OptionDefinition[];
}

const sectionsBeforeRenderers: UsageSection[] = [
    {
        header: "Synopsis",
        content: `$ quicktype [[bold]{--lang} ${langs}] FILE|URL ...`
    },
    {
        header: "Description",
        content: `Given JSON sample data, quicktype outputs code for working with that data in ${langDisplayNames}.`
    },
    {
        header: "Options",
        optionList: optionDefinitions
    }
];
const sectionsAfterRenderers: UsageSection[] = [
    {
        header: "Examples",
        content: [
            chalk.dim("Generate C# to parse a Bitcoin API"),
            "$ quicktype -o LatestBlock.cs https://blockchain.info/latestblock",
            "",
            chalk.dim("Generate Go code from a directory of samples containing:"),
            chalk.dim(
                `  - Foo.json
  + Bar
    - bar-sample-1.json
    - bar-sample-2.json
  - Baz.url`
            ),
            "$ quicktype -l go samples",
            "",
            chalk.dim("Generate JSON Schema, then TypeScript"),
            "$ quicktype -o schema.json https://blockchain.info/latestblock",
            "$ quicktype -o bitcoin.ts --src-lang schema schema.json"
        ]
    },
    {
        content: "Learn more at [bold]{quicktype.io}"
    }
];

function getTargetLanguage(name: string): TargetLanguage {
    const language = targetLanguages.languageNamed(name);
    if (language) {
        return language;
    }
    console.error(`'${name}' is not yet supported as an output language.`);
    return process.exit(1);
}

function usage() {
    const rendererSections: UsageSection[] = [];

    _.forEach(targetLanguages.all, language => {
        const definitions = language.optionDefinitions;
        if (definitions.length === 0) return;

        rendererSections.push({
            header: `Options for ${language.displayName}`,
            optionList: definitions
        });
    });

    const sections = _.concat(sectionsBeforeRenderers, rendererSections, sectionsAfterRenderers);

    console.log(getUsage(sections));
}

export type RendererOptions = { [name: string]: string };

export interface Options {
    lang?: string;
    src?: string[];
    topLevel?: string;
    srcLang?: string;
    srcUrls?: string;
    graphql?: string;
    out?: string;
    noMaps?: boolean;
    help?: boolean;
    quiet?: boolean;
    rendererOptions: RendererOptions;
}

interface CompleteOptions {
    lang: string;
    src: string[];
    topLevel: string;
    srcLang: string;
    srcUrls?: string;
    graphql?: string;
    out?: string;
    noMaps: boolean;
    help: boolean;
    quiet: boolean;
    rendererOptions: RendererOptions;
}

interface SampleOrSchemaMap {
    [key: string]: object[];
}

class Run {
    options: CompleteOptions;

    constructor(argv: string[] | Options) {
        if (_.isArray(argv)) {
            // We can only fully parse the options once we know which renderer is selected,
            // because there are renderer-specific options.  But we only know which renderer
            // is selected after we've parsed the options.  Hence, we parse the options
            // twice.  This is the first parse to get the renderer:
            const incompleteOptions = this.parseOptions(optionDefinitions, argv, true);
            const rendererOptionDefinitions = this.getOptionDefinitions(incompleteOptions);
            // Use the global options as well as the renderer options from now on:
            const allOptionDefinitions = _.concat(optionDefinitions, rendererOptionDefinitions);
            try {
                // This is the parse that counts:
                this.options = this.parseOptions(allOptionDefinitions, argv, false);
            } catch (error) {
                if (error.name === "UNKNOWN_OPTION") {
                    console.error("Error: Unknown option");
                    usage();
                    process.exit(1);
                }
                throw error;
            }
        } else {
            this.options = this.inferOptions(argv);
        }
    }

    getOptionDefinitions = (opts: CompleteOptions): OptionDefinition[] => {
        return getTargetLanguage(opts.lang).optionDefinitions;
    };

    renderSamplesOrSchemas = (samplesOrSchemas: SampleOrSchemaMap): SerializedRenderResult => {
        const areSchemas = this.options.srcLang === "schema";
        const targetLanguage = getTargetLanguage(this.options.lang);

        let config: Config = {
            language: targetLanguage.names[0],
            topLevels: Object.getOwnPropertyNames(samplesOrSchemas).map(name => {
                if (areSchemas) {
                    // Only one schema per top-level is used right now
                    return { name, schema: samplesOrSchemas[name][0] };
                } else {
                    return { name, samples: samplesOrSchemas[name] };
                }
            }),
            inferMaps: !this.options.noMaps,
            rendererOptions: this.options.rendererOptions
        };

        try {
            return targetLanguage.transformAndRenderConfig(config);
        } catch (e) {
            console.error(e);
            return process.exit(1);
        }
    };

    splitAndWriteJava = (dir: string, str: string) => {
        const lines = str.split("\n");
        let filename: string | null = null;
        let currentFileContents: string = "";

        const writeFile = () => {
            if (filename != null) {
                fs.writeFileSync(path.join(dir, filename), currentFileContents);
            }
            filename = null;
            currentFileContents = "";
        };

        let i = 0;
        while (i < lines.length) {
            const line = lines[i];
            i += 1;

            const results = line.match("^// (.+\\.java)$");
            if (results == null) {
                currentFileContents += line + "\n";
            } else {
                writeFile();
                filename = results[1];
                while (lines[i] === "") i++;
            }
        }
        writeFile();
    };

    render = (samplesOrSchemas: SampleOrSchemaMap) => {
        const { lines, annotations } = this.renderSamplesOrSchemas(samplesOrSchemas);
        const output = lines.join("\n");
        if (this.options.out) {
            if (this.options.lang === "java") {
                this.splitAndWriteJava(path.dirname(this.options.out), output);
            } else {
                fs.writeFileSync(this.options.out, output);
            }
        } else {
            process.stdout.write(output);
        }
        if (this.options.quiet) {
            return;
        }
        annotations.forEach((sa: Annotation) => {
            const annotation = sa.annotation;
            if (!(annotation instanceof IssueAnnotationData)) return;
            const lineNumber = sa.span.start.line;
            const humanLineNumber = lineNumber + 1;
            console.error(`\nIssue in line ${humanLineNumber}: ${annotation.message}`);
            console.error(`${humanLineNumber}: ${lines[lineNumber]}`);
        });
    };

    parseJsonFromStream = (stream: fs.ReadStream | NodeJS.Socket): Promise<object> => {
        return new Promise<object>(resolve => {
            let source = makeSource();
            let assembler = new Assembler();

            let assemble = chunk => assembler[chunk.name] && assembler[chunk.name](chunk.value);
            let isInt = intString => /^\d+$/.test(intString);

            let intSentinelChunks = intString => [
                { name: "startObject" },
                { name: "startKey" },
                { name: "stringChunk", value: Main.intSentinel },
                { name: "endKey" },
                { name: "keyValue", value: Main.intSentinel },
                { name: "startNumber" },
                { name: "numberChunk", value: intString },
                { name: "endNumber" },
                { name: "numberValue", value: intString },
                { name: "endObject" }
            ];

            // FIXME: this is all completely untyped
            let queue: any[] = [];
            source.output.on("data", chunk => {
                switch (chunk.name) {
                    case "startNumber":
                    case "numberChunk":
                    case "endNumber":
                        // We queue number chunks until we decide if they are int
                        queue.push(chunk);
                        break;
                    case "numberValue":
                        queue.push(chunk);
                        if (isInt(chunk.value)) {
                            intSentinelChunks(chunk.value).forEach(assemble);
                        } else {
                            queue.forEach(assemble);
                        }
                        queue = [];
                        break;
                    default:
                        assemble(chunk);
                }
            });

            source.output.on("end", () => resolve(assembler.current));

            stream.setEncoding("utf8");
            stream.pipe(source.input);
            stream.resume();
        });
    };

    mapValues = async (obj: object, f: (val: any) => Promise<any>): Promise<any> => {
        let result = {};
        for (let key of Object.keys(obj)) {
            result[key] = await f(obj[key]);
        }
        return result;
    };

    readNamedSamplesFromDirectory = async (dataDir: string): Promise<SampleOrSchemaMap> => {
        const readFilesOrURLsInDirectory = async (d: string): Promise<SampleOrSchemaMap> => {
            let samples: SampleOrSchemaMap = {};
            const files = fs
                .readdirSync(d)
                .map(x => path.join(d, x))
                .filter(x => fs.lstatSync(x).isFile());
            // Each file is a (Name, JSON | URL)
            for (const file of files) {
                const sampleName = (() => {
                    let name = path.basename(file);
                    return name.substr(0, name.lastIndexOf("."));
                })();

                let fileOrUrl = file;
                // If file is a URL string, download it
                if (_.endsWith(file, ".url")) {
                    fileOrUrl = fs.readFileSync(file, "utf8").trim();
                }

                const sample = await this.parseFileOrUrl(fileOrUrl);
                samples[sampleName] = [sample];
            }
            return samples;
        };

        const contents = fs.readdirSync(dataDir).map(x => path.join(dataDir, x));
        const directories = contents.filter(x => fs.lstatSync(x).isDirectory());

        let allSamples = await readFilesOrURLsInDirectory(dataDir);
        for (const dir of directories) {
            const sampleName = path.basename(dir);
            const samples = await readFilesOrURLsInDirectory(dir);
            allSamples[sampleName] = _(samples)
                .values()
                .flatten()
                .value();
        }

        return allSamples;
    };

    parseFileOrUrl = async (fileOrUrl: string): Promise<object> => {
        if (fs.existsSync(fileOrUrl)) {
            return this.parseJsonFromStream(fs.createReadStream(fileOrUrl));
        } else {
            let res = await fetch(fileOrUrl);
            return this.parseJsonFromStream(res.body);
        }
    };

    parseFileOrUrlArray = (filesOrUrls: string[]): Promise<object[]> => {
        return Promise.all(filesOrUrls.map(this.parseFileOrUrl));
    };

    main = async () => {
        if (this.options.help) {
            usage();
        } else if (this.options.srcUrls) {
            let json = JSON.parse(fs.readFileSync(this.options.srcUrls, "utf8"));
            let jsonMap = fromRight(Main.urlsFromJsonGrammar(json));
            this.render(await this.mapValues(jsonMap, this.parseFileOrUrlArray));
        } else if (this.options.graphql) {
            let json = JSON.parse(fs.readFileSync(this.options.graphql, "utf8"));
            readGraphQLSchema(json);
        } else if (this.options.src.length === 0) {
            let samples: SampleOrSchemaMap = {};
            samples[this.options.topLevel] = [await this.parseJsonFromStream(process.stdin)];
            this.render(samples);
        } else {
            let samples: SampleOrSchemaMap = {};
            const directories = this.options.src.filter(x => fs.lstatSync(x).isDirectory());
            const files = this.options.src.filter(x => fs.lstatSync(x).isFile());

            for (const dataDir of directories) {
                const moreSamples = await this.readNamedSamplesFromDirectory(dataDir);
                samples = _.merge(samples, moreSamples);
            }

            if (!_.isEmpty(files)) {
                samples[this.options.topLevel] = await this.parseFileOrUrlArray(files);
            }

            this.render(samples);
        }
    };

    // Parse the options in argv and split them into global options and renderer options,
    // according to each option definition's `renderer` field.  If `partial` is false this
    // will throw if it encounters an unknown option.
    parseOptions = (
        definitions: OptionDefinition[],
        argv: string[],
        partial: boolean
    ): CompleteOptions => {
        const opts: { [key: string]: any } = commandLineArgs(definitions, {
            argv,
            partial: partial
        });
        const options: Options = { rendererOptions: {} };
        definitions.forEach(o => {
            if (!(o.name in opts)) return;
            const v = opts[o.name];
            if (o.renderer) options.rendererOptions[o.name] = v;
            else {
                const k = _.lowerFirst(
                    o.name
                        .split("-")
                        .map(_.upperFirst)
                        .join("")
                );
                options[k] = v;
            }
        });
        return this.inferOptions(options);
    };

    inferOptions = (opts: Options): CompleteOptions => {
        return {
            src: opts.src || [],
            srcLang: opts.srcLang || "json",
            lang: opts.lang || this.inferLang(opts),
            topLevel: opts.topLevel || this.inferTopLevel(opts),
            noMaps: !!opts.noMaps,
            help: !!opts.help,
            quiet: !!opts.quiet,
            ...opts
        };
    };

    inferLang = (options: Options): string => {
        // Output file extension determines the language if language is undefined
        if (options.out) {
            let extension = path.extname(options.out);
            if (extension === "") {
                console.error("Please specify a language (--lang) or an output file extension.");
                process.exit(1);
            }
            return extension.substr(1);
        }

        return "go";
    };

    inferTopLevel = (options: Options): string => {
        // Output file name determines the top-level if undefined
        if (options.out) {
            let extension = path.extname(options.out);
            let without = path.basename(options.out).replace(extension, "");
            return without;
        }

        // Source determines the top-level if undefined
        if (options.src && options.src.length === 1) {
            let src = options.src[0];
            let extension = path.extname(src);
            let without = path.basename(src).replace(extension, "");
            return without;
        }

        return "TopLevel";
    };
}

export async function main(args: string[] | Options) {
    if (_.isArray(args) && args.length === 0) {
        usage();
    } else {
        let run = new Run(args);
        await run.main();
    }
}

if (require.main === module) {
    main(process.argv.slice(2)).catch(reason => {
        console.error(reason);
        process.exit(1);
    });
}
