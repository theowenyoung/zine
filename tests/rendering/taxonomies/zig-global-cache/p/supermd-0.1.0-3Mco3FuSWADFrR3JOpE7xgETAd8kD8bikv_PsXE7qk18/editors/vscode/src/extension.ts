import {
    // createStdioOptions,
    startServer
} from '@vscode/wasm-wasi-lsp';
import { ProcessOptions, Stdio, Wasm } from '@vscode/wasm-wasi';
import { ExtensionContext, languages, Uri, window, workspace } from 'vscode';
import {
    LanguageClient,
    LanguageClientOptions,
    ServerOptions
} from 'vscode-languageclient/node';
import { SuperFormatProvider } from './formatter';


let client: LanguageClient;
export async function activate(context: ExtensionContext) {
    const wasm: Wasm = await Wasm.load();

    const channel = window.createOutputChannel('SuperHTML Language Server');
    // The server options to run the WebAssembly language server.
    const serverOptions: ServerOptions = async () => {
        const options: ProcessOptions = {
            stdio: createStdioOptions(),
            // mountPoints: [{ kind: 'workspaceFolder' }]
        };

        // Load the WebAssembly code
        const filename = Uri.joinPath(
            context.extensionUri,
            'wasm',
            'superhtml.wasm'
        );
        const bits = await workspace.fs.readFile(filename);
        const module = await WebAssembly.compile(bits);

        // Create the wasm worker that runs the LSP server
        const process = await wasm.createProcess(
            'superhtml',
            module,
            { initial: 160, maximum: 160, shared: false },
            options
        );

        // Hook stderr to the output channel
        const decoder = new TextDecoder('utf-8');
        process.stderr!.onData(data => {
            channel.append(decoder.decode(data));
        });

        // process.stdin!.write("banana".repeat(10000));
        // process.stdin!.write("cake");

        return startServer(process);
    };

    const clientOptions: LanguageClientOptions = {
        documentSelector: [
            { scheme: "file", language: 'html' },
            { scheme: "file", language: 'superhtml' },
        ],
        outputChannel: channel,
    };

    client = new LanguageClient(
        "superhtml",
        "SuperHTML Language Server",
        serverOptions,
        clientOptions
    );

    context.subscriptions.push(
        languages.registerDocumentFormattingEditProvider(
            [{ scheme: "file", language: "html" }],
            new SuperFormatProvider(client),
        ),
        languages.registerDocumentRangeFormattingEditProvider(
            [{ scheme: "file", language: "html" }],
            new SuperFormatProvider(client),
        ),
        languages.registerDocumentFormattingEditProvider(
            [{ scheme: "file", language: "superhtml" }],
            new SuperFormatProvider(client),
        ),
        languages.registerDocumentRangeFormattingEditProvider(
            [{ scheme: "file", language: "superhtml" }],
            new SuperFormatProvider(client),
        ),
    );

    await client.start();

}

export function deactivate(): Thenable<void> | undefined {
    if (!client) {
        return undefined;
    }
    return client.stop();
}


function createStdioOptions(): Stdio {
    return {
        in: {
            kind: 'pipeIn',
        },
        out: {
            kind: 'pipeOut'
        },
        err: {
            kind: 'pipeOut'
        }
    };
}
