import 'package:json_annotation/json_annotation.dart';

part 'model_329.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model329 {
  const Model329({required this.id, required this.value});

  final int id;
  final String value;

  factory Model329.fromJson(Map<String, dynamic> json) =>
      _$Model329FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model329ToJson(this);
}
