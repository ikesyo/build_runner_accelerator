import 'package:json_annotation/json_annotation.dart';

part 'model_425.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model425 {
  const Model425({required this.id, required this.value});

  final int id;
  final String value;

  factory Model425.fromJson(Map<String, dynamic> json) =>
      _$Model425FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model425ToJson(this);
}
