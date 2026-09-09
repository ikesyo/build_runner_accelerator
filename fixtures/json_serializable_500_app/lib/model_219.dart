import 'package:json_annotation/json_annotation.dart';

part 'model_219.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model219 {
  const Model219({required this.id, required this.value});

  final int id;
  final String value;

  factory Model219.fromJson(Map<String, dynamic> json) =>
      _$Model219FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model219ToJson(this);
}
