import A "Asset";
import Array "mo:base/Array";
import B "Batch";
import Blob "mo:base/Blob";
import Buffer "mo:base/Buffer";
import C "Chunk";
import CertifiedData "mo:base/CertifiedData";
import Char "mo:base/Char";
import Debug "mo:base/Debug";
import Error "mo:base/Error";
import Hash "mo:base/Hash";
import HashMap "mo:base/HashMap";
import Iter "mo:base/Iter";
import Nat "mo:base/Nat";
import Option "mo:base/Option";
import Prim "mo:prim";
import Principal "mo:base/Principal";
import Result "mo:base/Result";
import T "Types";
import Text "mo:base/Text";
import Time "mo:base/Time";
import Trie "mo:base/Trie";
import U "Utils";

shared ({caller = creator}) actor class () {
    type Bio = {
        givenName: ?Text;
        familyName: ?Text;
        name: ?Text;
        displayName: ?Text;
        location: ?Text;
        about: ?Text;
    };

    type Profile = {
        bio: Bio;
        id: Principal;
        image: ?Image;
    };
    
    type ProfileUpdate = {
        bio: Bio;
        image: ?Image;
    };

    type Image = {
        fileName: Text;
        data: Blob;
        filetype: Text;
    };

    type Error = {
        #NotFound;
        #AlreadyExists;
        #NotAuthorized;
    };

    // Application state
    stable var profiles : Trie.Trie<Principal, Profile> = Trie.empty();

    stable var authorized: [Principal] = [creator];

    // Asset management
    stable var stableAssets : [(T.Key, A.StableAsset)] = [];
    
    let assets = HashMap.fromIter<T.Key, A.Asset>(Iter.map(stableAssets.vals(), A.toAssetEntry), 7, Text.equal, Text.hash);
    
    let chunks = C.Chunks();
    let batches = B.Batches();

    system func preupgrade() {
        stableAssets := Iter.toArray(Iter.map(assets.entries(), A.toStableAssetEntry));
    };

    system func postupgrade() {
        stableAssets := [];
    };

    // Application interface

    // Create a profile
    public shared(msg) func create (profile: ProfileUpdate) : async Result.Result<(), Error> {
        // Get caller principal
        let callerId = msg.caller;

        // Reject AnonymousIdentity
        if(Principal.toText(callerId) == "2vxsx-fae") {
            return #err(#NotAuthorized);
        };

        // Associate user profile with their principal
        let userProfile: Profile = {
            bio = profile.bio;
            image = profile.image;
            id = callerId;
        };

        let (newProfiles, existing) = Trie.put(
            profiles,           // Target trie
            key(callerId),      // Key
            Principal.equal,    // Equality checker
            userProfile
        );


        switch(profile.image){
            case null {};
            case (? v){
                var fileName = "/images/";
                fileName := Text.concat(fileName, Principal.toText(callerId));
                fileName := Text.concat(fileName, "/");
                fileName := Text.concat(fileName, v.fileName);
                let sha256 : ?Blob = null;

                let storeResult = await store({
                    key = fileName;
                    content_type = v.filetype;
                    content_encoding = "identity";
                    content = v.data;
                    sha256 = sha256;
                });
            };
        };

        // If there is an original value, do not update
        switch(existing) {
            // If there are no matches, update profiles
            case null {
                profiles := newProfiles;
                #ok(());
            };
            // Matches pattern of type - opt Profile
            case (? v) {
                #err(#AlreadyExists);
            };
        };
    };

    // Read profile
    public shared(msg) func read () : async Result.Result<Profile, Error> {
        // Get caller principal
        let callerId = msg.caller;

        // Reject AnonymousIdentity
        if(Principal.toText(callerId) == "2vxsx-fae") {
            return #err(#NotAuthorized);
        };

        let result = Trie.find(
            profiles,           //Target Trie
            key(callerId),      // Key
            Principal.equal     // Equality Checker
        );
        return Result.fromOption(result, #NotFound);
    };

    // Update profile
    public shared(msg) func update (profile : ProfileUpdate) : async Result.Result<(), Error> {
        // Get caller principal
        let callerId = msg.caller;

        // Reject AnonymousIdentity
        if(Principal.toText(callerId) == "2vxsx-fae") {
            return #err(#NotAuthorized);
        };

        // Associate user profile with their principal
        let userProfile: Profile = {
            bio = profile.bio;
            image = profile.image;
            id = callerId;
        };

        let result = Trie.find(
            profiles,           //Target Trie
            key(callerId),     // Key
            Principal.equal           // Equality Checker
        );

        switch(profile.image){
            case null {};
            case (? v){
                var fileName = "/images/";
                fileName := Text.concat(fileName, Principal.toText(callerId));
                fileName := Text.concat(fileName, "/");
                fileName := Text.concat(fileName, v.fileName);
                let sha256 : ?Blob = null;

                let deleteResult = delete_asset({key = fileName});

                let storeResult = await store({
                    key = fileName;
                    content_type = v.filetype;
                    content_encoding = "identity";
                    content = v.data;
                    sha256 = sha256;
                });
            };
        };

        switch (result){
            // Do not allow updates to profiles that haven't been created yet
            case null {
                #err(#NotFound)
            };
            case (? v) {
                profiles := Trie.replace(
                    profiles,           // Target trie
                    key(callerId),      // Key
                    Principal.equal,    // Equality checker
                    ?userProfile
                ).0;
                #ok(());
            };
        };
    };

    // Delete profile
    public shared(msg) func delete () : async Result.Result<(), Error> {
        // Get caller principal
        let callerId = msg.caller;

        // Reject AnonymousIdentity
        if(Principal.toText(callerId) == "2vxsx-fae") {
            return #err(#NotAuthorized);
        };

        let result = Trie.find(
            profiles,           //Target Trie
            key(callerId),      // Key
            Principal.equal     // Equality Checker
        );

        switch (result){
            // Do not try to delete a profile that hasn't been created yet
            case null {
                #err(#NotFound);
            };
            case (? v) {
                profiles := Trie.replace(
                    profiles,           // Target trie
                    key(callerId),     // Key
                    Principal.equal,          // Equality checker
                    null
                ).0;
                #ok(());
            };
        };
    };

    private func key(x : Principal) : Trie.Key<Principal> {
        return { key = x; hash = Principal.hash(x) }
    };
    private func keyText(x : Text) : Trie.Key<Text> {
        return { key = x; hash = Text.hash(x) }
    };

    // **********************
    // Asset Management Logic
    // **********************

    // Store a content encoding for an asset.  Does not remove other content encodings.
    // If the contents exceed the message ingress limit,
    // use create_batch(), create_chunk(), commit_batch() instead.
    private func store(arg:{
        key: T.Key;
        content_type: Text;
        content_encoding: Text;
        content: Blob;
        sha256: ?Blob;
    }) : async () {
        let batch = batches.create();
        let chunkId = chunks.create(batch, arg.content);

        let create_asset_args : T.CreateAssetArguments = {
            key = arg.key;
            content_type = arg.content_type;
        };
        switch(createAsset(create_asset_args)) {
            case (#ok(())) {};
            case (#err(msg)) throw Error.reject(msg);
        };

        let args : T.SetAssetContentArguments = {
            key = arg.key;
            content_encoding = arg.content_encoding;
            chunk_ids = [ chunkId ];
            sha256 = arg.sha256;
        };
        switch(setAssetContent(args)) {
            case (#ok(())) {};
            case (#err(msg)) throw Error.reject(msg);
        };
    };

    func entryToAssetDetails((key: T.Key, asset: A.Asset)) : T.AssetDetails {
        let assetEncodings = Iter.toArray(
            Iter.map<(Text, A.AssetEncoding), T.AssetEncodingDetails>(
                asset.encodingEntries(), entryToAssetEncodingDetails
            )
        );
        {
            key = key;
            content_type = asset.contentType;
            encodings = assetEncodings;
        }
    };
  func entryToAssetEncodingDetails((name: Text, assetEncoding: A.AssetEncoding)) : T.AssetEncodingDetails {
    {
      modified = Time.now();
      content_encoding = assetEncoding.contentEncoding;
      sha256 = assetEncoding.sha256;
      length = assetEncoding.totalLength;
    }
  };

  public query func list(arg:{}) : async [T.AssetDetails] {
    let iter = Iter.map<(Text, A.Asset), T.AssetDetails>(assets.entries(), entryToAssetDetails);
    Iter.toArray(iter)
  };

  func isSafe(caller: Principal) : Bool {
    func eq(value: Principal): Bool = value == caller;
    Array.find(authorized, eq) != null
  };

  // 1. Choose a content encoding from among the accepted encodings.
  // 2. Return its content, or the first chunk of its content.
  //
  // If content.size() > total_length, caller must call get_chunk() get the rest of the content.
  // All chunks except the last will have the same size as the first chunk.
  public query func get(arg:{
    key: T.Key;
    accept_encodings: [Text]
  }) : async ( {
    content: Blob;
    content_type: Text;
    content_encoding: Text;
    total_length: Nat;
    sha256: ?Blob;
  } ) {
    switch (assets.get(arg.key)) {
      case null throw Error.reject("asset not found");
      case (?asset) {
        switch (asset.chooseEncoding(arg.accept_encodings)) {
          case null throw Error.reject("no such encoding");
          case (?encoding) {
            {
              content = encoding.content[0];
              content_type = asset.contentType;
              content_encoding = encoding.contentEncoding;
              total_length = encoding.totalLength;
              sha256 = encoding.sha256;
            }
          }
        };
      };
    };
  };

  // Get subsequent chunks of an asset encoding's content, after get().
  public query func get_chunk(arg:{
    key: T.Key;
    content_encoding: Text;
    index: Nat;
    sha256: ?Blob;
  }) : async ( {
    content: Blob
  }) {
    switch (assets.get(arg.key)) {
      case null throw Error.reject("asset not found");
      case (?asset) {
        switch (asset.getEncoding(arg.content_encoding)) {
          case null throw Error.reject("no such encoding");
          case (?encoding) {
            switch (arg.sha256, encoding.sha256) {
              case (?expected, ?actual) {
                if (expected != actual)
                  throw Error.reject("sha256 mismatch");
              };
              case (?expected, null) throw Error.reject("sha256 specified but asset encoding has none");
              case (null, _) {};
            };

            {
              content = encoding.content[arg.index];
            }
          }
        };
      };
    };
  };

  // All chunks are associated with a batch until committed with commit_batch.
  public shared ({ caller }) func create_batch(arg: {}) : async ({
    batch_id: T.BatchId
  }) {
    if (isSafe(caller) == false)
      throw Error.reject("not authorized");

    batches.deleteExpired();
    chunks.deleteExpired();

    {
      batch_id = batches.create().batchId;
    }
  };

  public shared ({ caller }) func create_chunk( arg: {
    batch_id: T.BatchId;
    content: Blob;
  } ) : async ({
    chunk_id: T.ChunkId
  }) {
    //Debug.print("create_chunk(batch " # Int.toText(arg.batch_id) # ", " # Int.toText(arg.content.size()) # " bytes)");
    if (isSafe(caller) == false)
      throw Error.reject("not authorized");

    let chunkId = switch (batches.get(arg.batch_id)) {
      case null throw Error.reject("batch not found");
      case (?batch) chunks.create(batch, arg.content)
    };

    {
      chunk_id = chunkId;
    }
  };

  public shared ({ caller }) func commit_batch(args: T.CommitBatchArguments) : async () {
    //Debug.print("commit_batch (" # Int.toText(args.operations.size()) # ")");
    if (isSafe(caller) == false)
      throw Error.reject("not authorized");

    for (op in args.operations.vals()) {
      let r : Result.Result<(), Text> = switch(op) {
        case (#CreateAsset(args)) { createAsset(args); };
        case (#SetAssetContent(args)) { setAssetContent(args); };
        case (#UnsetAssetContent(args)) { unsetAssetContent(args); };
        case (#DeleteAsset(args)) { deleteAsset(args); };
        case (#Clear(args)) { doClear(args); }
      };
      switch(r) {
        case (#ok(())) {};
        case (#err(msg)) throw Error.reject(msg);
      };
    };
    batches.delete(args.batch_id);
  };

  public shared ({ caller }) func create_asset(arg: T.CreateAssetArguments) : async () {
    if (isSafe(caller) == false)
      throw Error.reject("not authorized");

    switch(createAsset(arg)) {
      case (#ok(())) {};
      case (#err(err)) throw Error.reject(err);
    };
  };

  func createAsset(arg: T.CreateAssetArguments) : Result.Result<(), Text> {
    //Debug.print("createAsset(" # arg.key # ")");
    switch (assets.get(arg.key)) {
      case null {
        let asset = A.Asset(
          arg.content_type,
          HashMap.HashMap<Text, A.AssetEncoding>(7, Text.equal, Text.hash)
        );
        assets.put(arg.key, asset );
      };
      case (?asset) {
        if (asset.contentType != arg.content_type)
          return #err("create_asset: content type mismatch");
      }
    };
    #ok(())
  };

  public shared ({ caller }) func set_asset_content(arg: T.SetAssetContentArguments) : async () {
    if (isSafe(caller) == false)
      throw Error.reject("not authorized");

    switch(setAssetContent(arg)) {
      case (#ok(())) {};
      case (#err(err)) throw Error.reject(err);
    };
  };

  func chunkLengthsMatch(chunks: [Blob]): Bool {
    if (chunks.size() > 2) {
      let expectedLength = chunks[0].size();
      for (i in Iter.range(1, chunks.size()-2)) {
        //Debug.print("chunk at index " # Int.toText(i) # " has length " # Int.toText(chunks[i].size()) # " and expected is " # Int.toText(expectedLength) );
        if (chunks[i].size() != expectedLength) {
          //Debug.print("chunk at index " # Int.toText(i) # " with length " # Int.toText(chunks[i].size()) # " does not match expected length " # Int.toText(expectedLength) );

          return false;
        }
      };
    };
    true
  };

  func setAssetContent(arg: T.SetAssetContentArguments) : Result.Result<(), Text> {
    //Debug.print("setAssetContent(" # arg.key # ")");
    switch (assets.get(arg.key)) {
      case null #err("asset not found");
      case (?asset) {
        switch (Array.mapResult<T.ChunkId, Blob, Text>(arg.chunk_ids, chunks.take)) {
          case (#ok(chunks)) {
            if (chunkLengthsMatch(chunks) == false) {
              #err(arg.key # "(" # arg.content_encoding # "): chunk lengths do not match the size of the first chunk")
            } else if (chunks.size() == 0) {
              #err(arg.key # "(" # arg.content_encoding # "): must have at least one chunk")
            } else {
              let encoding : A.AssetEncoding = {
                modified = Time.now();
                contentEncoding = arg.content_encoding;
                content = chunks;
                totalLength = Array.foldLeft<Blob, Nat>(chunks, 0, func (acc: Nat, blob: Blob): Nat {
                  acc + blob.size()
                });
                sha256 = arg.sha256;
              };
              #ok(asset.setEncoding(arg.content_encoding, encoding));
            };
          };
          case (#err(err)) #err(err);
        };
      };
    }
  };

  public shared ({ caller }) func unset_asset_content(args: T.UnsetAssetContentArguments) : async () {
    if (isSafe(caller) == false)
      throw Error.reject("not authorized");

    switch(unsetAssetContent(args)) {
      case (#ok(())) {};
      case (#err(err)) throw Error.reject(err);
    };
  };

  func unsetAssetContent(args: T.UnsetAssetContentArguments) : Result.Result<(), Text> {
    //Debug.print("unsetAssetContent(" # args.key # ")");
    switch (assets.get(args.key)) {
      case null #err("asset not found");
      case (?asset) {
        asset.unsetEncoding(args.content_encoding);
        #ok(())
      };
    };
  };

  public shared ({ caller }) func delete_asset(args: T.DeleteAssetArguments) : async () {
    if (isSafe(caller) == false)
      throw Error.reject("not authorized");

    switch(deleteAsset(args)) {
      case (#ok(())) {};
      case (#err(err)) throw Error.reject(err);
    };
  };

  func deleteAsset(args: T.DeleteAssetArguments) : Result.Result<(), Text> {
    //Debug.print("deleteAsset(" # args.key # ")");
    if (assets.size() > 0) {   // avoid div/0 bug   https://github.com/dfinity/motoko-base/issues/228
      assets.delete(args.key);
    };
    #ok(())
  };

  public shared ({ caller }) func clear(args: T.ClearArguments) : async () {
    if (isSafe(caller) == false)
      throw Error.reject("not authorized");

    switch(doClear(args)) {
      case (#ok(())) {};
      case (#err(err)) throw Error.reject(err);
    };
  };

  func doClear(args: T.ClearArguments) : Result.Result<(), Text> {
    stableAssets := [];
    U.clearHashMap(assets);

    batches.reset();
    chunks.reset();

    #ok(())
  };

  public query func http_request(request: T.HttpRequest): async T.HttpResponse {
    let key = switch(urlDecode(getKey(request.url))) {
      case (#ok(decoded)) decoded;
      case (#err(msg)) throw Error.reject("error decoding url: " # msg);
    };
    let acceptEncodings = getAcceptEncodings(request.headers);

    let assetAndEncoding: ?(A.Asset, A.AssetEncoding) = switch (getAssetAndEncoding(key, acceptEncodings)) {
      case (?found) ?found;
      case (null) getAssetAndEncoding("/index.html", acceptEncodings);
    };


    switch (assetAndEncoding) {
      case null {{ status_code = 404; headers = []; body = ""; streaming_strategy = null }};
      case (?(asset, assetEncoding)) {
        let streaming_strategy = switch(makeNextToken(key, assetEncoding, 0)) {
          case (?token) ?#Callback {
            callback = http_request_streaming_callback;
            token = token;
          };
          case null null;
        };

        let headers = Buffer.Buffer<T.HeaderField>(2);
        headers.add(("Content-Type", asset.contentType));
        if (assetEncoding.contentEncoding != "identity") {
          headers.add(("Content-Encoding", assetEncoding.contentEncoding));
        };

        {
          status_code = 200;
          headers = headers.toArray();
          body = assetEncoding.content[0];
          streaming_strategy = streaming_strategy;
        }
      };
    }
  };

  func getAcceptEncodings(headers: [T.HeaderField]): [Text] {
    let accepted_encodings = Buffer.Buffer<Text>(2);
    for (header in headers.vals()) {
      // todo: remove direct dependency on Prim https://github.com/dfinity/sdk/issues/1598
      let k = Text.map(header.0, Prim.charToUpper);
      let v = header.1;
      // todo: use caseInsensitiveTextEqual, see https://github.com/dfinity/sdk/issues/1599
      if (k == "ACCEPT-ENCODING") {
        for (t in Text.split(v, #char ',')) {
          let encoding = Text.trim(t, #char ' ');
          accepted_encodings.add(encoding);
        }
      }
    };
    // last choice
    accepted_encodings.add("identity");

    accepted_encodings.toArray()
  };

  // todo: use this once Text.compareWith uses its cmp parameter https://github.com/dfinity/sdk/issues/1599
  //func caseInsensitiveTextEqual(s1: Text, s2: Text): Bool {
  //  switch(Text.compareWith(s1, s2, caseInsensitiveCharCompare)) {
  //    case (#equal) true;
  //    case _ false;
  //  }
  //};

  func caseInsensitiveCharCompare(c1: Char, c2: Char) : { #less; #equal; #greater } {
    Char.compare(Prim.charToUpper(c1), Prim.charToUpper(c2))
  };

  // Get subsequent chunks of an asset encoding's content, after http_request().
  // Like get_chunk, but converts url to key
  public query func http_request_streaming_callback(token: T.StreamingCallbackToken) : async T.StreamingCallbackHttpResponse {
    switch (assets.get(token.key)) {
      case null throw Error.reject("asset not found");
      case (?asset) {
        switch (asset.getEncoding(token.content_encoding)) {
          case null throw Error.reject("no such encoding");
          case (?encoding) {
            switch (token.sha256, encoding.sha256) {
              case (?expected, ?actual) {
                if (expected != actual)
                  throw Error.reject("sha256 mismatch");
              };
              case (?expected, null) throw Error.reject("sha256 specified but asset encoding has none");
              case (null, _) {};
            };

            {
              body = encoding.content[token.index];
              token = makeNextToken(token.key, encoding, token.index);
            }
          }
        };
      };
    };
  };

  private func makeNextToken(key: T.Key, assetEncoding: A.AssetEncoding, lastIndex: Nat): ?T.StreamingCallbackToken {
    if (lastIndex + 1 < assetEncoding.content.size()) {
      ?{
        key = key;
        content_encoding = assetEncoding.contentEncoding;
        index = lastIndex + 1;
        sha256 = assetEncoding.sha256;
      };
    } else {
      null;
    };
  };

  private func getKey(uri: Text): Text {
    let splitted = Text.split(uri, #char '?');
    let array = Iter.toArray<Text>(splitted);
    let path = array[0];
    path
  };

  private func getAssetAndEncoding(path: Text, acceptEncodings: [Text]): ?(A.Asset, A.AssetEncoding) {
    switch (assets.get(path)) {
      case null null;
      case (?asset) {
        switch (asset.chooseEncoding(acceptEncodings)) {
          case null null;
          case (?assetEncoding) ?(asset, assetEncoding);
        }
      }
    }
  };

  private func urlDecode(encoded: Text): Result.Result<Text, Text> {
    var decoded = "";
    let iter = Text.toIter(encoded);
    loop {
      switch (iter.next()) {
        case null return #ok(decoded);
        case (? '%') {
          switch (iter.next()) {
            case null return #err("% must be followed by '%' or two hex digits");
            case (? '%') decoded #= "%";
            case (?first) {
              switch (iter.next()) {
                case null return #err("% must be followed by two hex digits, but only one was found");
                case (?second) {
                  switch (hexCharAsNibble(first), hexCharAsNibble(second)) {
                    case (?hi, ?lo) decoded #= Char.toText(Char.fromNat32(hi << 4 | lo));
                    case (null, ?_) return #err("first character after % is not a hex digit");
                    case (?_, null) return #err("second character after % is not a hex digit");
                    case (null, null) return #err("neither character after % is a hex digit");
                  };
                };
              };
            };
          };
        };
        case (?c) decoded #= Char.toText(c);
      };
    };
  };

  private func hexCharAsNibble(c: Char): ?Nat32 {
    let n = Char.toNat32(c);

    let asDigit = n -% Char.toNat32('0');
    if (asDigit <= (9 : Nat32)) {
      return ?asDigit;
    };

    let asLowerHexDigit = n -% Char.toNat32('a');
    if (asLowerHexDigit <= (5 : Nat32)) {
      return ?(0xA + asLowerHexDigit);
    };

    let asUpperHexDigit = n -% Char.toNat32('A');
    if (asUpperHexDigit <= (5 : Nat32)) {
      return ?(0xA + asUpperHexDigit);
    };

    null
  };

}
