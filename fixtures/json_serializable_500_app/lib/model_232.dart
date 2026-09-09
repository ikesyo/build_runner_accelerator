import 'package:json_annotation/json_annotation.dart';

part 'model_232.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model232 {
  const Model232({required this.id, required this.value});

  final int id;
  final String value;

  factory Model232.fromJson(Map<String, dynamic> json) =>
      _$Model232FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model232ToJson(this);
}
