import 'package:json_annotation/json_annotation.dart';

part 'model_04.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model04 {
  const Model04({required this.id, required this.value});

  final int id;
  final String value;

  factory Model04.fromJson(Map<String, dynamic> json) =>
      _$Model04FromJson(json);

  Map<String, dynamic> toJson() => _$Model04ToJson(this);
}
