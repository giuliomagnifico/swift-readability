const path = require('path');
const webpack = require('webpack');
const HtmlWebpackPlugin = require('html-webpack-plugin');
const fs = require('fs');

module.exports = {
    mode: "production",
    entry: {
        AtDocumentStart: "./webpack-resources/AtDocumentStart.js",
        Readability: "./webpack-resources/Readability.js",
    },
    output: {
        path: path.resolve(__dirname, 'Sources'),
        filename: (pathData) => {
            const chunkName = pathData.chunk.name;
            if (chunkName === 'AtDocumentStart') {
                return 'ReadabilityUI/Resources/[name].js';
            } else {
                return 'Readability/Resources/[name].js';
            }
        }
    },
    module: {
        rules: [
            {
                test: /[/\\]@mozilla[/\\]readability[/\\]Readability\.js$/,
                use: path.resolve(__dirname, 'webpack-resources/readability-debug-loader.js')
            },
            {
                test: /\.css$/,
                use: [
                    'css-loader',
                    'raw-loader'
                ]
            }
        ]
    },
    plugins: [
        new HtmlWebpackPlugin({
            template: './webpack-resources/Reader.html',
            filename: 'ReadabilityUI/Resources/Reader.html',
            inject: false,
            templateParameters: {
                css: fs.readFileSync('./webpack-resources/Reader.css', 'utf8')
            },
            minify: false
        }),
        new webpack.DefinePlugin({
            __READABILITY_OPTIONS__: JSON.stringify({
                debug: false,
                maxElemsToParse: 0,
                nbTopCandidates: 5
            })
        })
    ]
};
