import 'package:json_annotation/json_annotation.dart';

part 'model_005.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model005 {
  const Model005({required this.id, required this.value});

  final int id;
  final String value;

  factory Model005.fromJson(Map<String, dynamic> json) =>
      _$Model005FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model005ToJson(this);
}
