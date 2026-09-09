import 'package:json_annotation/json_annotation.dart';

part 'model_374.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model374 {
  const Model374({required this.id, required this.value});

  final int id;
  final String value;

  factory Model374.fromJson(Map<String, dynamic> json) =>
      _$Model374FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model374ToJson(this);
}
