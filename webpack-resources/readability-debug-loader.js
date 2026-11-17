// Avoid serializing the article for a discarded debug log in Mozilla Readability.
module.exports = function(source) {
    const log = 'this.log("Grabbed: " + articleContent.innerHTML);';
    if (source.split(log).length !== 2) {
        throw new Error("Mozilla Readability's article debug log changed; review the debug guard.");
    }
    return source.replace(log, `if (this._debug) {\n      ${log}\n    }`);
};
