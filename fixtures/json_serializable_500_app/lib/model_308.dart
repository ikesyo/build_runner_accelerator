import 'package:json_annotation/json_annotation.dart';

part 'model_308.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model308 {
  const Model308({required this.id, required this.value});

  final int id;
  final String value;

  factory Model308.fromJson(Map<String, dynamic> json) =>
      _$Model308FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model308ToJson(this);
}
