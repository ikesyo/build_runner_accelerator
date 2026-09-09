import 'package:json_annotation/json_annotation.dart';

part 'model_214.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model214 {
  const Model214({required this.id, required this.value});

  final int id;
  final String value;

  factory Model214.fromJson(Map<String, dynamic> json) =>
      _$Model214FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model214ToJson(this);
}
