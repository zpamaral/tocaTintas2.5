/*
Copyright (c) 2026 Zé Pedro do Amaral <amaral@mac.com>

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/
//
//  ZPCatalogoDaApple.h
//  tocaTintas
//
//  Created by J. Pedro Sousa do Amaral on 01/11/2026.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// O catálogo público da Apple (a pesquisa do iTunes): o álbum de uma faixa do
// Música, as faixas dele e a capa. Um só sítio para a janela, a gravação e o
// processamento automático, que antes procuravam cada um à sua maneira (em
// 2026-11, o processamento não achou o «Antics» dos Interpol, que a janela
// achava pelo artista).
//
// A procura, em cada loja: primeiro o artista e, entre os álbuns dele, o que
// tiver esse nome (acha os discos de nomes comuns, e os que a pesquisa por
// texto não devolve: «Interpol Antics» dava 0 resultados); depois, por texto,
// o álbum pelo artista e pelo nome; por fim, se houver título, a faixa pelo
// artista e pelo título, e dela o álbum. O nome compara-se sem maiúsculas,
// acentos nem pontuação; fora do modo exacto também sem os sufixos de edição
// («(Deluxe Version)», «- EP», «- Single»). Entre os que servem, o do mesmo
// artista passa à frente (há «Bloom» de mais de um).
//
// Tudo numa fila própria, em série e de prioridade utilitária: um pedido de
// cada vez à Apple, que limita os pedidos por minuto, e nada no thread
// principal. As respostas ficam em memória (também as que não acharam nada):
// as faixas seguintes do mesmo álbum não voltam a perguntar.
@interface ZPCatalogoDaApple : NSObject

// O álbum, com os campos da pesquisa do iTunes (collectionId, collectionName,
// artistName, artworkUrl100…), na primeira das lojas («us», «pt»…) que o
// tiver; nil se nenhuma. Em `exacto`, só o mesmo nome: é o modo das etiquetas,
// em que outra edição traria outras faixas. Síncrono e demorado (pedidos à
// rede): nunca no thread principal.
+ (nullable NSDictionary *)albumDe:(NSString *)artista
                           chamado:(NSString *)album
                            titulo:(nullable NSString *)titulo
                             lojas:(NSArray<NSString *> *)lojas
                            exacto:(BOOL)exacto;

// As faixas («song») de um álbum, na loja de onde ele veio. Síncrono.
+ (NSArray<NSDictionary *> *)faixasDoAlbum:(NSDictionary *)album;

// A capa do álbum a `lado` píxeis, ou nil. Síncrono.
+ (nullable NSData *)capaDoAlbum:(NSDictionary *)album lado:(NSUInteger)lado;

// A loja do país do Mac, a de onde o Música tira os nomes.
+ (NSString *)lojaDoMac;

// A capa de uma faixa do Música a 600 px, na loja do Mac e sem modo exacto,
// entregue no thread principal (nil se não houver). Não bloqueia.
+ (void)capaDe:(NSString *)artista
         album:(NSString *)album
        titulo:(nullable NSString *)titulo
     concluido:(void (^)(NSData *_Nullable capa))concluido;

// O número de uma faixa do Música no seu disco e quantas o disco tem, pelo
// catálogo da loja do Mac (o Música dá 0 aos dois nas faixas do catálogo). A
// faixa acha-se pelo nome; senão pela duração, a menos de 1,5 s, se só uma
// cair aí. Entregue no thread principal; 0 e 0 se não se souber. Não bloqueia.
+ (void)posicaoDe:(NSString *)artista
            album:(NSString *)album
           titulo:(NSString *)titulo
          duracao:(double)duracao
        concluido:(void (^)(NSInteger faixa, NSInteger total))concluido;

@end

NS_ASSUME_NONNULL_END
