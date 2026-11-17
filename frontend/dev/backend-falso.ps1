# Backend falso, só para testar a tela (Main.elm) sem FastAPI nem Prolog.
#
# Segue o contrato do Api.elm e copia as regras do domino.pl. Também serve
# os arquivos do frontend, então basta abrir http://localhost:8000.
#
# Uso (no PowerShell, dentro de frontend/):
#   elm make src/Main.elm --output=build/main.js
#   powershell -ExecutionPolicy Bypass -File dev/backend-falso.ps1
#
# Não é o backend de verdade: quem decide no jogo final é o Prolog.

param([int]$Port = 8000)

$root = Split-Path -Parent $PSScriptRoot

Add-Type -ReferencedAssemblies System.Web.Extensions -TypeDefinition @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Text;
using System.Web.Script.Serialization;

public class Rejected : Exception { public Rejected(string m) : base(m) {} }

public class GameState {
    public List<int[]> Player, Opponent, Table, Boneyard;
    public string Turn;
}

public static class FakeBackend {
    static readonly Random Rng = new Random();
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer();

    // ---------------------------------------------------------------- servidor

    public static void Run(int port, string root) {
        var listener = new HttpListener();
        listener.Prefixes.Add("http://localhost:" + port + "/");
        listener.Start();
        Console.WriteLine("Backend falso em http://localhost:" + port + "/  (feche a janela para parar)");
        while (true) {
            var ctx = listener.GetContext();
            try { Handle(ctx, root); }
            catch (Exception e) { Console.WriteLine("  erro: " + e.Message); TrySend(ctx, 500, "{\"detail\":\"erro no backend falso\"}"); }
        }
    }

    static void Handle(HttpListenerContext ctx, string root) {
        var req = ctx.Request;
        var path = req.Url.AbsolutePath;
        ctx.Response.AddHeader("Access-Control-Allow-Origin", "*");
        ctx.Response.AddHeader("Access-Control-Allow-Methods", "POST, GET, OPTIONS");
        ctx.Response.AddHeader("Access-Control-Allow-Headers", "Content-Type");

        if (req.HttpMethod == "OPTIONS") { Send(ctx, 204, "", "text/plain"); return; }
        if (req.HttpMethod == "GET") { ServeFile(ctx, root, path); return; }

        string body;
        using (var r = new StreamReader(req.InputStream, Encoding.UTF8)) body = r.ReadToEnd();
        Console.WriteLine("POST " + path + " " + body);

        try {
            object answer;
            switch (path) {
                case "/new-game": answer = NewGame(); break;
                case "/play": answer = Play(Parse(body)); break;
                case "/opponent-move": answer = OpponentMove(Parse(body)); break;
                case "/hint": answer = Hint(Parse(body)); break;
                default: Send(ctx, 404, "{\"detail\":\"rota desconhecida\"}", "application/json"); return;
            }
            var text = Json.Serialize(answer);
            Console.WriteLine("  -> " + text);
            Send(ctx, 200, text, "application/json");
        } catch (Rejected e) {
            Console.WriteLine("  -> 400 " + e.Message);
            Send(ctx, 400, Json.Serialize(new Dictionary<string, object> { { "detail", e.Message } }), "application/json");
        }
    }

    static void ServeFile(HttpListenerContext ctx, string root, string path) {
        if (path == "/") path = "/index.html";
        var file = Path.GetFullPath(Path.Combine(root, Uri.UnescapeDataString(path.TrimStart('/'))));
        if (!file.StartsWith(Path.GetFullPath(root)) || !File.Exists(file)) { Send(ctx, 404, "não encontrado", "text/plain"); return; }
        var types = new Dictionary<string, string> {
            { ".html", "text/html" }, { ".js", "text/javascript" }, { ".css", "text/css" },
            { ".svg", "image/svg+xml" }, { ".jpg", "image/jpeg" }, { ".png", "image/png" } };
        string type;
        if (!types.TryGetValue(Path.GetExtension(file).ToLower(), out type)) type = "application/octet-stream";
        var bytes = File.ReadAllBytes(file);
        ctx.Response.StatusCode = 200;
        ctx.Response.ContentType = type + (type.StartsWith("text") ? "; charset=utf-8" : "");
        ctx.Response.OutputStream.Write(bytes, 0, bytes.Length);
        ctx.Response.Close();
    }

    static void Send(HttpListenerContext ctx, int status, string text, string type) {
        var bytes = Encoding.UTF8.GetBytes(text);
        ctx.Response.StatusCode = status;
        ctx.Response.ContentType = type + "; charset=utf-8";
        ctx.Response.OutputStream.Write(bytes, 0, bytes.Length);
        ctx.Response.Close();
    }

    static void TrySend(HttpListenerContext ctx, int status, string text) {
        try { Send(ctx, status, text, "application/json"); } catch { }
    }

    // ---------------------------------------------------------------- JSON

    static Dictionary<string, object> Parse(string body) {
        try { return (Dictionary<string, object>)Json.DeserializeObject(body); }
        catch { throw new Rejected("JSON inválido."); }
    }

    static GameState ReadState(Dictionary<string, object> req) {
        if (!req.ContainsKey("state")) throw new Rejected("Faltou o campo state.");
        var s = (Dictionary<string, object>)req["state"];
        return new GameState {
            Player = Pieces(s["player_hand"]), Opponent = Pieces(s["opponent_hand"]),
            Table = Pieces(s["table"]), Boneyard = Pieces(s["boneyard"]), Turn = (string)s["turn"] };
    }

    static List<int[]> Pieces(object o) {
        var list = new List<int[]>();
        foreach (var x in (IList)o) { var p = (IList)x; list.Add(new[] { Convert.ToInt32(p[0]), Convert.ToInt32(p[1]) }); }
        return list;
    }

    static Dictionary<string, object> Reply(GameState s, int[] startPiece) {
        var reply = new Dictionary<string, object> {
            { "state", new Dictionary<string, object> {
                { "player_hand", s.Player }, { "opponent_hand", s.Opponent },
                { "table", s.Table }, { "boneyard", s.Boneyard }, { "turn", s.Turn } } },
            { "result", GameOver(s) } };
        if (startPiece != null) reply["start_piece"] = startPiece;
        return reply;
    }

    static object MoveJson(int[] piece, string side) { return new object[] { piece, side }; }

    // ---------------------------------------------------------------- rotas

    static object NewGame() {
        var all = new List<int[]>();
        for (int a = 0; a <= 6; a++) for (int b = a; b <= 6; b++) all.Add(new[] { a, b });
        var shuffled = all.OrderBy(_ => Rng.Next()).ToList();
        var s = new GameState {
            Player = shuffled.Take(7).ToList(), Opponent = shuffled.Skip(7).Take(7).ToList(),
            Table = new List<int[]>(), Boneyard = shuffled.Skip(14).ToList() };
        string turn; var start = Starter(s.Player, s.Opponent, out turn);
        s.Turn = turn;
        return Reply(s, start);
    }

    static object Play(Dictionary<string, object> req) {
        var s = ReadState(req);
        if (s.Turn != "player") throw new Rejected("Não é a sua vez.");
        if (GameOver(s) != null) throw new Rejected("A partida já acabou.");
        var action = req.ContainsKey("action") ? req["action"] : null;

        if (action is string && (string)action == "draw") {
            if (Moves(s.Player, s.Table).Count > 0) throw new Rejected("Você ainda tem peça que encaixa: não precisa comprar.");
            if (s.Boneyard.Count == 0) throw new Rejected("O monte acabou.");
            s.Player.Add(s.Boneyard[0]); s.Boneyard.RemoveAt(0);
            return Reply(s, null);
        }
        if (action is string && (string)action == "pass") {
            if (Moves(s.Player, s.Table).Count > 0) throw new Rejected("Você ainda tem peça que encaixa: não dá para passar.");
            if (s.Boneyard.Count > 0) throw new Rejected("Ainda tem peça no monte: compre antes de passar.");
            s.Turn = "opponent";
            return Reply(s, null);
        }
        var move = action as IList;
        if (move == null || move.Count != 2) throw new Rejected("Ação inválida.");
        var piece = Pieces(new object[] { move[0] })[0];
        var side = (string)move[1];
        if (s.Table.Count == 0) {
            string ignored; var start = Starter(s.Player, s.Opponent, out ignored);
            if (!Same(piece, start)) throw new Rejected("A partida abre com a " + Text(start) + ".");
        }
        PlayPiece(s.Player, s.Table, piece, side);
        s.Turn = "opponent";
        return Reply(s, null);
    }

    // A vez inteira do computador: abre com a peça de saída, ou compra até
    // ter jogada (draw_until_playable/6) e joga (choose_move/3), ou passa.
    static object OpponentMove(Dictionary<string, object> req) {
        var s = ReadState(req);
        if (s.Turn != "opponent") throw new Rejected("Não é a vez do computador.");
        if (GameOver(s) == null) {
            if (s.Table.Count == 0) {
                string ignored; var start = Starter(s.Player, s.Opponent, out ignored);
                PlayPiece(s.Opponent, s.Table, start, "right");
            } else {
                while (Moves(s.Opponent, s.Table).Count == 0 && s.Boneyard.Count > 0) {
                    s.Opponent.Add(s.Boneyard[0]); s.Boneyard.RemoveAt(0);
                }
                var best = Choose(s.Opponent, s.Table);
                if (best != null) PlayPiece(s.Opponent, s.Table, best.Item1, best.Item2);
            }
        }
        s.Turn = "player";
        return Reply(s, null);
    }

    static object Hint(Dictionary<string, object> req) {
        var s = ReadState(req);
        var best = Choose(s.Player, s.Table);
        object hint = best != null ? MoveJson(best.Item1, best.Item2) : (s.Boneyard.Count > 0 ? (object)"draw" : "pass");
        return new Dictionary<string, object> { { "hint", hint } };
    }

    // ---------------------------------------------------------------- regras (domino.pl)

    static int Rank(int[] p) { return p[0] == p[1] ? 100 + p[0] : p[0] + p[1]; }

    static int[] Starter(List<int[]> player, List<int[]> opponent, out string turn) {
        var p = player.OrderByDescending(Rank).First();
        var o = opponent.OrderByDescending(Rank).First();
        turn = Rank(p) >= Rank(o) ? "player" : "opponent";
        return turn == "player" ? p : o;
    }

    static bool Same(int[] a, int[] b) {
        return (a[0] == b[0] && a[1] == b[1]) || (a[0] == b[1] && a[1] == b[0]);
    }

    static bool Fits(int[] p, List<int[]> table, string side) {
        if (table.Count == 0) return side == "right";
        int n = side == "left" ? table[0][0] : table[table.Count - 1][1];
        return p[0] == n || p[1] == n;
    }

    static List<Tuple<int[], string>> Moves(List<int[]> hand, List<int[]> table) {
        var moves = new List<Tuple<int[], string>>();
        foreach (var p in hand)
            foreach (var side in new[] { "left", "right" })
                if (Fits(p, table, side)) moves.Add(Tuple.Create(p, side));
        return moves;
    }

    static void PlayPiece(List<int[]> hand, List<int[]> table, int[] piece, string side) {
        var inHand = hand.FirstOrDefault(p => Same(p, piece));
        if (inHand == null) throw new Rejected("A " + Text(piece) + " não está na sua mão.");
        if (side != "left" && side != "right") throw new Rejected("Lado inválido: " + side + ".");
        if (!Fits(inHand, table, side))
            throw new Rejected("A " + Text(piece) + " não encaixa na ponta " + (side == "left" ? "esquerda" : "direita") + ".");
        hand.Remove(inHand);
        int a = inHand[0], b = inHand[1];
        if (table.Count == 0) table.Add(new[] { a, b });
        else if (side == "left") table.Insert(0, b == table[0][0] ? new[] { a, b } : new[] { b, a });
        else table.Add(a == table[table.Count - 1][1] ? new[] { a, b } : new[] { b, a });
    }

    // move_score/4: pontos da peça, +5 se for bucha, +2 por peça que continua jogável.
    static int Score(Tuple<int[], string> move, List<int[]> hand, List<int[]> table) {
        var h = new List<int[]>(hand); var t = new List<int[]>(table);
        PlayPiece(h, t, move.Item1, move.Item2);
        var p = move.Item1;
        return p[0] + p[1] + (p[0] == p[1] ? 5 : 0) + 2 * h.Count(x => Fits(x, t, "left") || Fits(x, t, "right"));
    }

    // choose_move/3: a de maior nota; no empate, a primeira.
    static Tuple<int[], string> Choose(List<int[]> hand, List<int[]> table) {
        Tuple<int[], string> best = null; int top = int.MinValue;
        foreach (var m in Moves(hand, table)) { var sc = Score(m, hand, table); if (sc > top) { top = sc; best = m; } }
        return best;
    }

    static int Points(List<int[]> hand) { return hand.Sum(p => p[0] + p[1]); }

    // game_over/6: batida ou trancado; null enquanto há jogo.
    static object GameOver(GameState s) {
        string winner = null; int points = 0;
        if (s.Player.Count == 0) { winner = "player"; points = Points(s.Opponent); }
        else if (s.Opponent.Count == 0) { winner = "opponent"; points = Points(s.Player); }
        else if (s.Boneyard.Count == 0 && s.Table.Count > 0
                 && Moves(s.Player, s.Table).Count == 0 && Moves(s.Opponent, s.Table).Count == 0) {
            int pp = Points(s.Player), op = Points(s.Opponent);
            if (pp < op) { winner = "player"; points = op; }
            else if (pp > op) { winner = "opponent"; points = pp; }
            else { winner = "draw"; points = 0; }
        }
        if (winner == null) return null;
        return new Dictionary<string, object> { { "winner", winner }, { "points", points } };
    }

    static string Text(int[] p) { return p[0] + "|" + p[1]; }
}
'@

[FakeBackend]::Run($Port, $root)
